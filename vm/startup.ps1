<#
  Runs as SYSTEM at every boot (set as the VM's `windows-startup-script-ps1` metadata; see README).
  Its output goes to the VM's serial port 1, readable with:
      gcloud compute instances get-serial-port-output rdp-desktop --zone=europe-west1-b
    1. Turns account lockout off. Bots try thousands of passwords a day on any open RDP port and kept locking
       the account; a 15-character random password can't be guessed at that rate, so lockout only hurt you.
    2. Unlocks any locked local account.
    3. Prints who failed to sign in during the last 24 h, so you can see what caused a lockout.
    4. Installs and starts the "RDP Unlock Watcher" task (the website's Unlock button) from the
       `rdp-unlock-watcher` metadata key.
#>

$dir = "C:\ProgramData\rdp-autosuspend"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

net accounts /lockoutthreshold:0 | Out-Null
Write-Output "rdp-startup: account lockout disabled"

foreach ($name in (Get-LocalUser | Where-Object Enabled).Name) {
  $u = [ADSI]"WinNT://$env:COMPUTERNAME/$name,user"
  if ($u.InvokeGet("IsAccountLocked")) {
    $u.InvokeSet("IsAccountLocked", $false)
    $u.CommitChanges()
    Write-Output "rdp-startup: unlocked $name"
  }
}

$since = (Get-Date).AddDays(-1)
$failed = Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4625; StartTime = $since } -MaxEvents 20000 -ErrorAction SilentlyContinue
Write-Output "rdp-startup: $(@($failed).Count) failed sign-ins in the last 24 h"
$failed | Group-Object { "$($_.Properties[5].Value) from $($_.Properties[19].Value)" } |
  Sort-Object Count -Descending | Select-Object -First 15 |
  ForEach-Object { Write-Output "rdp-startup:   $($_.Count) x $($_.Name)" }
Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4740; StartTime = $since } -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Output "rdp-startup: locked out $($_.Properties[0].Value) at $($_.TimeCreated.ToString('s'))" }

try {
  $code = Invoke-RestMethod -Headers @{ "Metadata-Flavor" = "Google" } `
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/rdp-unlock-watcher"
  Stop-ScheduledTask -TaskName "RDP Unlock Watcher" -ErrorAction SilentlyContinue
  Set-Content -Path "$dir\unlock-watcher.ps1" -Value $code -Encoding UTF8
  $action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\unlock-watcher.ps1`""
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName "RDP Unlock Watcher" -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Settings $settings -User "SYSTEM" -RunLevel Highest -Force | Out-Null
  Start-ScheduledTask -TaskName "RDP Unlock Watcher"
  Write-Output "rdp-startup: unlock watcher running"
} catch {
  Write-Output "rdp-startup: unlock watcher not installed: $($_.Exception.Message)"
}
