<#
.SYNOPSIS
  Charge an EV via a Zaptec charger up to a target battery percentage (default 80%).

.DESCRIPTION
  A Zaptec charger does NOT know the car's state of charge (plain AC charging
  carries no SoC). This script ESTIMATES the percentage from the energy the
  charger delivers after you start it:

      estimated% = start% + (delivered kWh * efficiency / usable capacity) * 100

  It starts/resumes charging, polls delivered energy every -IntervalSec seconds,
  prints progress, and PAUSES (resumable) once the target is reached.

  Notes:
    * This is an estimate. Pass the percentage the car shows RIGHT NOW.
    * The charger can enable charging, but the car can still refuse to draw power
      (e.g. an in-car / app charge timer). The script warns if no power flows.
    * Tune -Efficiency if it consistently over- or under-shoots.

.EXAMPLE
  $env:ZAPTEC_CHARGER_ID = "<your-charger-id>"   # find with: zaptec-pp-cli chargers list
  ./charge-to.ps1 -StartPercent 66

.EXAMPLE
  ./charge-to.ps1 -StartPercent 50 -Target 90 -CapacityKwh 59 -ChargerId <id>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateRange(0, 100)]
  [double]$StartPercent,

  [ValidateRange(1, 100)]
  [double]$Target = 80,

  # Usable battery capacity in kWh. Nissan Leaf 40 kWh ~= 39 usable; Leaf e+ 62 kWh ~= 59.
  [double]$CapacityKwh = 39,

  # AC charging efficiency (the charger delivers more than reaches the battery).
  [ValidateRange(0.5, 1.0)]
  [double]$Efficiency = 0.90,

  # Charger id. Defaults to $env:ZAPTEC_CHARGER_ID. Find it with: zaptec-pp-cli chargers list
  [string]$ChargerId = $env:ZAPTEC_CHARGER_ID,

  [int]$IntervalSec = 60,

  [switch]$DryRun
)

# Do NOT let a native command's stderr (e.g. a transient "server error 500,
# retrying" warning the CLI prints while it retries) abort the whole script.
$ErrorActionPreference = "Continue"
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not $ChargerId) {
  throw "No charger id. Pass -ChargerId or set `$env:ZAPTEC_CHARGER_ID. Find it with: zaptec-pp-cli chargers list"
}

$cli = (Get-Command zaptec-pp-cli -ErrorAction SilentlyContinue).Source
if (-not $cli) { $cli = Join-Path $HOME "go\bin\zaptec-pp-cli.exe" }
if (-not (Test-Path $cli)) { throw "zaptec-pp-cli not found on PATH or in ~/go/bin." }

function Invoke-Cli {
  # Runs the CLI with stderr suppressed (PowerShell 5.1 otherwise turns native
  # stderr into a terminating NativeCommandError). Returns stdout text.
  param([string[]]$CliArgs)
  return (& $cli @CliArgs 2>$null)
}

function Get-State {
  # Returns @{ Energy = <session kWh>; Mode = <text>; Power = <W> }
  $raw = Invoke-Cli @("state", $ChargerId, "--json")
  if (-not $raw) { throw "Could not read charger state. Logged in?  $cli auth login" }
  $obs = $raw | ConvertFrom-Json
  function Val($id) {
    $r = $obs | Where-Object { $_.state_id -eq $id } | Select-Object -First 1
    if ($r) { return [string]$r.value } else { return $null }
  }
  $energy = 0.0; [void][double]::TryParse((Val 553), [Globalization.NumberStyles]::Float, $inv, [ref]$energy)
  $power  = 0.0; [void][double]::TryParse((Val 513), [Globalization.NumberStyles]::Float, $inv, [ref]$power)
  $mode = Val 710; if (-not $mode) { $mode = "Unknown" }
  return @{ Energy = $energy; Mode = $mode; Power = $power }
}

if ($Target -le $StartPercent) {
  Write-Error "Target ($Target%) must be higher than start ($StartPercent%)."
  exit 2
}

$neededIntoBattery = ($Target - $StartPercent) / 100.0 * $CapacityKwh
$neededDelivered   = $neededIntoBattery / $Efficiency

Write-Host ("Target: {0}% -> {1}%  |  battery {2} kWh usable  |  efficiency {3:P0}" -f $StartPercent, $Target, $CapacityKwh, $Efficiency)
Write-Host ("Into battery: {0:N2} kWh   =>   charger must deliver: ~{1:N2} kWh" -f $neededIntoBattery, $neededDelivered)

$state = Get-State
$baseline = $state.Energy
Write-Host ("Session energy now (baseline): {0:N2} kWh  |  mode: {1}" -f $baseline, $state.Mode)

if ($DryRun) {
  Write-Host ("[dry-run] No commands sent. Would charge until ~{0:N2} kWh extra delivered." -f $neededDelivered)
  exit 0
}

if ($state.Mode -ne "Charging") {
  Write-Host "Starting/resuming charging..."
  Invoke-Cli @("resume", $ChargerId) | Out-Null
  Invoke-Cli @("start", $ChargerId)  | Out-Null
  Start-Sleep -Seconds 6
  $state = Get-State
  if ($state.Energy -lt $baseline) { $baseline = 0.0 }   # a new session started
}

Write-Host "Monitoring (Ctrl-C to stop without pausing)..."
$noPowerPolls = 0
while ($true) {
  $s = Get-State
  $delivered = $s.Energy - $baseline
  if ($delivered -lt 0) { $baseline = 0.0; $delivered = $s.Energy }
  $estSoC = $StartPercent + ($delivered * $Efficiency / $CapacityKwh) * 100.0
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host ("[{0}] mode={1} | power {2:N0} W | delivered {3:N2} kWh | est ~{4:N1}%" -f $ts, $s.Mode, $s.Power, $delivered, $estSoC)

  if ($estSoC -ge $Target -or $delivered -ge $neededDelivered) {
    Write-Host ("Target ~{0}% reached -> pausing." -f $Target)
    Invoke-Cli @("pause", $ChargerId) | Out-Null
    break
  }
  if ($s.Mode -eq "Disconnected") { Write-Host "Charger disconnected - stopped monitoring."; break }

  # The charger enabled charging but the car draws ~no power: most likely an
  # in-car / app charge timer or the car considers itself done.
  if ($s.Power -lt 100) {
    $noPowerPolls++
    if ($noPowerPolls -eq 2) {
      Write-Warning "Charger is in '$($s.Mode)' but the car is not drawing power. Check for a charge timer/schedule in the car or the NissanConnect app. Still monitoring..."
    }
  } else {
    $noPowerPolls = 0
  }

  Start-Sleep -Seconds $IntervalSec
}
Write-Host "Done."
