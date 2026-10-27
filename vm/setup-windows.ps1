#Requires -RunAsAdministrator
<#
  One-time setup for the cloud Windows desktop (Windows Server 2022 on Compute Engine).
  Run inside the VM, in an elevated PowerShell, while signed in as the account you use every day:

      powershell -ExecutionPolicy Bypass -File C:\setup\setup-windows.ps1

  What it does:
    1. Makes Compute Engine "Suspend" work (hibernation off, display never sleeps).
    2. Makes sure disconnected RDP sessions are never logged off, and you always reconnect to the same session.
    3. Makes RDP smoother (UDP transport, H.264/AVC 444, 60 fps).
    4. Makes Server feel like a desktop (sound on, full visual effects, no Server Manager pop-up).
    5. Installs the auto-suspend task (suspends the VM after 30 min with nobody connected).
#>

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Set-Reg($path, $name, $value, $type = "DWord") {
  if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
  New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}

Step "Suspend support: hibernation off, monitor and sleep timeouts off"
powercfg -h off
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg -a

$ts = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"

Step "RDP sessions: never log off disconnected sessions, one session per user"
Set-Reg $ts "MaxDisconnectionTime" 0   # 0 = never end a disconnected session
Set-Reg $ts "MaxIdleTime" 0            # 0 = no idle limit
Set-Reg $ts "MaxConnectionTime" 0      # 0 = no limit on active sessions
Set-Reg $ts "fResetBroken" 0           # on a time limit, disconnect instead of logging off
Set-Reg $ts "fSingleSessionPerUser" 1  # reconnect to your existing session

Step "Security: lock an account for 15 min after 10 wrong passwords (slows RDP brute force)"
net accounts /lockoutthreshold:10 /lockoutwindow:15 /lockoutduration:15

Step "RDP smoothness: UDP transport, AVC 444, 60 fps"
Set-Reg $ts "SelectTransport" 0        # use both UDP and TCP
Set-Reg $ts "AVC444ModePreferred" 1
Set-Reg $ts "AVCHardwareEncodePreferred" 1
Set-Reg "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" "DWMFRAMEINTERVAL" 15  # 60 fps
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

Step "Sound: enable Windows Audio (disabled by default on Server)"
Set-Service -Name Audiosrv -StartupType Automatic
Set-Service -Name AudioEndpointBuilder -StartupType Automatic
Start-Service -Name AudioEndpointBuilder, Audiosrv

Step "Desktop feel: full visual effects, no Server Manager at sign-in"
Set-Reg "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 1  # best appearance
Set-Reg "HKCU:\Control Panel\Desktop" "FontSmoothing" "2" "String"
Get-ScheduledTask -TaskName "ServerManager" -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
Set-Reg "HKLM:\SOFTWARE\Microsoft\ServerManager" "DoNotOpenServerManagerAtLogon" 1

Step "Auto-suspend: install the idle watcher"
$dir = "C:\ProgramData\rdp-autosuspend"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
# Let your normal (non-elevated) user write the Claude heartbeat and keepawake files here.
icacls $dir /grant "*S-1-5-32-545:(OI)(CI)M" | Out-Null
foreach ($f in "autosuspend.ps1", "overnight.ps1", "PROMPT.example.md") {
  Copy-Item -Path (Join-Path $PSScriptRoot $f) -Destination "$dir\$f" -Force
}
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$dir\autosuspend.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "RDP Auto-Suspend" -Action $action -Trigger $trigger -Settings $settings `
  -User "SYSTEM" -RunLevel Highest -Force | Out-Null

gpupdate /force | Out-Null

Write-Host "`nDone. Sign out and back in once (or reboot) so every setting applies." -ForegroundColor Green
Write-Host "Then test: close the RDP window, press Suspend on the website, Resume, reconnect - your apps should still be open."
