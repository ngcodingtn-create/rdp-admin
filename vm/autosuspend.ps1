<#
  Suspends this Compute Engine VM once nobody is using it:
    - no RDP connection, AND
    - Claude Code hasn't written to any session log for $IdleMinutes (it writes on every step), AND
    - no overnight runner has touched its heartbeat-<pid> file for $IdleMinutes, AND
    - no "keepawake" file exists (create it to keep the VM on no matter what; delete it to go back to normal).
  Installed by setup-windows.ps1 as the "RDP Auto-Suspend" scheduled task (runs as SYSTEM every 5 min).
  Log: C:\ProgramData\rdp-autosuspend\log.txt

  -Now  suspend immediately unless someone is connected over RDP, keepawake is set, or another
        overnight runner is still working (used by overnight.ps1 when it finishes).

  Needs: the VM's service account allowed to call compute.instances.suspend on this VM,
  and the VM's access scope set to cloud-platform (see README).
#>
param([switch]$Now)

$IdleMinutes = 30
$dir = "C:\ProgramData\rdp-autosuspend"
$stateFile = "$dir\state.json"
$logFile = "$dir\log.txt"
$keepAwake = "$dir\keepawake"
$now = Get-Date

function Log($msg) { Add-Content -Path $logFile -Value "$($now.ToString('s'))  $msg" }
function Recent($time) { $time -and (($now - $time).TotalMinutes -lt $IdleMinutes) }

# Someone is connected if there is an established RDP TCP connection or an active rdp-tcp session.
$rdpPort = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp").PortNumber
$tcp = [bool](Get-NetTCPConnection -LocalPort $rdpPort -State Established -ErrorAction SilentlyContinue)
$session = [bool]((qwinsta 2>$null) -match "rdp-tcp#\S*\s+.*\s+Active")
$rdp = $tcp -or $session

# Each overnight runner touches its own heartbeat-<pid> file every minute.
$heartbeats = Get-ChildItem $dir -File -Filter "heartbeat*" -ErrorAction SilentlyContinue
$heartbeats | Where-Object { ($now - $_.LastWriteTime).TotalDays -gt 1 } | Remove-Item -ErrorAction SilentlyContinue
$runners = @($heartbeats | Where-Object { Recent $_.LastWriteTime }).Count

function Suspend-Vm($reason) {
  try {
    $md = "http://metadata.google.internal/computeMetadata/v1"
    $h = @{ "Metadata-Flavor" = "Google" }
    $token = (Invoke-RestMethod -Headers $h "$md/instance/service-accounts/default/token").access_token
    $project = Invoke-RestMethod -Headers $h "$md/project/project-id"
    $zone = (Invoke-RestMethod -Headers $h "$md/instance/zone").Split("/")[-1]
    $name = Invoke-RestMethod -Headers $h "$md/instance/name"

    Log "$reason; suspending $name"
    # Reset the timer first: after resume this script sees a fresh state.
    @{ idleSince = $now.ToString("o"); lastRun = $now.ToString("o") } | ConvertTo-Json | Set-Content $stateFile
    Invoke-RestMethod -Method Post -Headers @{ Authorization = "Bearer $token" } `
      "https://compute.googleapis.com/compute/v1/projects/$project/zones/$zone/instances/$name/suspend" | Out-Null
  } catch {
    Log "Suspend failed: $($_.Exception.Message)"
  }
}

if ($Now) {
  if ($rdp) { Log "Suspend requested but someone is connected over RDP; leaving it on"; exit 0 }
  if (Test-Path $keepAwake) { Log "Suspend requested but keepawake is set; leaving it on"; exit 0 }
  if ($runners) { Log "Suspend requested but $runners other overnight runner(s) still working; leaving it on"; exit 0 }
  Suspend-Vm "Suspend requested"
  exit 0
}

# Claude Code appends to its session logs (~\.claude\projects\...\*.jsonl) on every message and tool call.
$claudeLog = Get-ChildItem "C:\Users\*\.claude\projects" -Recurse -File -Filter *.jsonl -ErrorAction SilentlyContinue |
  Measure-Object -Property LastWriteTime -Maximum
$claude = Recent $claudeLog.Maximum
$busy = $rdp -or $claude -or $runners -or (Test-Path $keepAwake)

$state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }

# A gap since the last run means the VM was just resumed (or booted): resync the clock and restart the timer
# so we never suspend straight after a resume.
$justResumed = $state -and (($now - [datetime]$state.lastRun).TotalMinutes -gt 12)
if ($justResumed) {
  w32tm /resync /force | Out-Null
  Log "Resumed after a gap; clock resynced, idle timer reset"
}

if (-not $state -or $busy -or $justResumed) {
  @{ idleSince = $now.ToString("o"); lastRun = $now.ToString("o") } | ConvertTo-Json | Set-Content $stateFile
  exit 0
}

@{ idleSince = $state.idleSince; lastRun = $now.ToString("o") } | ConvertTo-Json | Set-Content $stateFile
$idleFor = ($now - [datetime]$state.idleSince).TotalMinutes
if ($idleFor -ge $IdleMinutes) {
  Suspend-Vm "No RDP connection and Claude idle for $([int]$idleFor) min"
}
