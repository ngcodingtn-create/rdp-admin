<#
  Runs as SYSTEM at every boot (set as the VM's `windows-startup-script-ps1` metadata; see README).
  Its output goes to the VM's serial port 1, readable with:
      gcloud compute instances get-serial-port-output rdp-desktop --zone=europe-west1-b
    0. Puts RDP on the port in the `rdp-port` metadata key and reports it as guest attribute rdp/port.
    0b. Extends C: into any space added by a disk resize.
    1. Turns account lockout off. Bots try thousands of passwords a day on any open RDP port and kept locking
       the account; a 15-character random password can't be guessed at that rate, so lockout only hurt you.
    2. Unlocks any locked local account.
    3. Prints who failed to sign in during the last 24 h, so you can see what caused a lockout.
    4. Installs and starts the "RDP Unlock Watcher" task (the website's Unlock button) from the
       `rdp-unlock-watcher` metadata key.
#>

$dir = "C:\ProgramData\rdp-autosuspend"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$md = "http://metadata.google.internal/computeMetadata/v1/instance"
$h = @{ "Metadata-Flavor" = "Google" }

# RDP port: the `rdp-port` metadata key (default 3389). A non-standard port avoids most internet bots.
$port = 3389
try { $port = [int](Invoke-RestMethod -Headers $h "$md/attributes/rdp-port") } catch {}
$ws = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
if ((Get-ItemProperty $ws).PortNumber -ne $port) {
  Set-ItemProperty $ws -Name PortNumber -Value $port -Type DWord
  Set-ItemProperty $ws -Name UdpPortNumber -Value $port -Type DWord
  # -Force also stops the services that depend on TermService (e.g. UmRdpService) and doesn't
  # start them again; without them a session can sit on a black screen. Start them explicitly.
  $dependents = (Get-Service TermService).DependentServices
  Restart-Service TermService -Force
  $dependents | Start-Service -ErrorAction SilentlyContinue
  Write-Output "rdp-startup: RDP moved to port $port"
}
Get-NetFirewallRule -DisplayName "RDP custom port*" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($port -ne 3389) {
  foreach ($proto in "TCP", "UDP") {
    New-NetFirewallRule -DisplayName "RDP custom port $proto" -Direction Inbound -Protocol $proto -LocalPort $port -Action Allow | Out-Null
  }
}
# Tell the website and the PC script which port to use (guest attribute rdp/port).
try { Invoke-RestMethod -Method Put -Headers $h -Body "$port" "$md/guest-attributes/rdp/port" | Out-Null } catch {}
Write-Output "rdp-startup: RDP listening on port $port"
# Make sure everything a session needs is running (an earlier version of this script left some stopped).
foreach ($svc in "TermService", "UmRdpService", "SessionEnv", "Audiosrv", "AudioEndpointBuilder") {
  $s = Get-Service $svc -ErrorAction SilentlyContinue
  if ($s -and $s.Status -ne "Running" -and $s.StartType -ne "Disabled") {
    Start-Service $svc -ErrorAction SilentlyContinue
    Write-Output "rdp-startup: started $svc"
  }
}

# Grow C: into any space added by `gcloud compute disks resize` (no-op when it already fills the disk).
try {
  Update-HostStorageCache
  $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
  if (($max - (Get-Partition -DriveLetter C).Size) -ge 1GB) {
    Resize-Partition -DriveLetter C -Size $max
    Write-Output "rdp-startup: extended C: to $([math]::Round($max / 1GB)) GB"
  }
} catch { Write-Output "rdp-startup: could not extend C: $($_.Exception.Message)" }

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
# Successful remote sign-ins (RDP = logon type 10, reconnect/unlock = 7, NLA pre-auth = 3 from an outside IP).
Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4624; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 20000 -ErrorAction SilentlyContinue |
  Where-Object { $_.Properties[8].Value -in 3, 7, 10 -and $_.Properties[18].Value -notin "-", "::1", "127.0.0.1", "" } |
  Group-Object { "$($_.Properties[5].Value) from $($_.Properties[18].Value) (type $($_.Properties[8].Value))" } |
  Sort-Object Count -Descending | Select-Object -First 15 |
  ForEach-Object { Write-Output "rdp-startup: SUCCESS last 7 days: $($_.Count) x $($_.Name)" }
Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = 4740; StartTime = $since } -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Output "rdp-startup: locked out $($_.Properties[0].Value) at $($_.TimeCreated.ToString('s'))" }

# Tailscale: a WireGuard mesh VPN so RDP works even when the local network blocks the public port.
# The VM joins the tailnet outbound (no inbound firewall rule) and gets a fixed 100.x address.
# The auth key comes from the `tailscale-authkey` metadata key, so no secret is ever in this repo.
# Set it once from Cloud Shell / the PC:
#   gcloud compute instances add-metadata rdp-desktop --zone=europe-west1-b --metadata=tailscale-authkey=tskey-...
# After the node is registered you can clear it again with --metadata=tailscale-authkey=.
try {
  $tsKey = $null
  try { $tsKey = Invoke-RestMethod -Headers $h "$md/attributes/tailscale-authkey" } catch {}
  $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
  if (-not (Test-Path $tsExe)) {
    $msi = "$env:TEMP\tailscale-setup.msi"
    Invoke-WebRequest -UseBasicParsing "https://pkgs.tailscale.com/stable/tailscale-setup-1.104.6-amd64.msi" -OutFile $msi
    Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /quiet /norestart TS_UNATTENDEDMODE=always"
    Write-Output "rdp-startup: Tailscale installed"
  }
  if ((Test-Path $tsExe) -and $tsKey -and ($tsKey.Trim() -like "tskey-*")) {
    & $tsExe up --auth-key=$($tsKey.Trim()) --unattended --hostname=rdp-desktop --accept-dns=false 2>&1 |
      ForEach-Object { Write-Output "rdp-startup: tailscale up: $_" }
    $tsIp = (& $tsExe ip -4 2>$null | Select-Object -First 1)
    if ($tsIp) {
      try { Invoke-RestMethod -Method Put -Headers $h -Body "$tsIp" "$md/guest-attributes/tailscale/ip" | Out-Null } catch {}
      Write-Output "rdp-startup: Tailscale IP $tsIp"
    }
  } elseif (-not $tsKey) {
    Write-Output "rdp-startup: no tailscale-authkey metadata; skipping Tailscale join"
  }
} catch { Write-Output "rdp-startup: Tailscale setup failed: $($_.Exception.Message)" }

# ngrok TCP relay: the VM dials OUT to ngrok's edge and ngrok publishes a public tcp://HOST:PORT
# that forwards to local RDP. Works even when the VM's own public IP is blocked by the client's
# network, because the client connects to ngrok, not to the VM. Authtoken from the `ngrok-authtoken`
# metadata key (no secret in the repo). Set it with:
#   gcloud compute instances add-metadata rdp-desktop --zone=europe-west1-b --metadata=ngrok-authtoken=<token>
# The current public endpoint is reported to the serial log and to guest attribute ngrok/endpoint.
try {
  $ngToken = $null
  try { $ngToken = Invoke-RestMethod -Headers $h "$md/attributes/ngrok-authtoken" } catch {}
  if ($ngToken -and $ngToken.Trim()) {
    $ngDir = "C:\ngrok"; New-Item -ItemType Directory -Force -Path $ngDir | Out-Null
    $ngExe = "$ngDir\ngrok.exe"
    if (-not (Test-Path $ngExe)) {
      $zip = "$env:TEMP\ngrok.zip"
      Invoke-WebRequest -UseBasicParsing "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" -OutFile $zip
      Expand-Archive -Path $zip -DestinationPath $ngDir -Force
      Write-Output "rdp-startup: ngrok downloaded"
    }
    # Config (v2 format, accepted by the v3 agent): one tcp tunnel to the RDP port, EU edge.
    @("version: `"2`"", "authtoken: $($ngToken.Trim())", "region: eu", "console_ui: false",
      "tunnels:", "  rdp:", "    proto: tcp", "    addr: $port") |
      Set-Content -Path "$ngDir\ngrok.yml" -Encoding ASCII
    # Clean any prior service/task, then run ngrok as a SYSTEM scheduled task that logs to a file.
    & $ngExe service stop 2>&1 | Out-Null
    & $ngExe service uninstall 2>&1 | Out-Null
    Unregister-ScheduledTask -TaskName "ngrok-rdp" -Confirm:$false -ErrorAction SilentlyContinue
    $ngLog = "$ngDir\ngrok.log"; Remove-Item $ngLog -ErrorAction SilentlyContinue
    $ngAct = New-ScheduledTaskAction -Execute $ngExe -Argument "start rdp --config `"$ngDir\ngrok.yml`" --log `"$ngLog`" --log-format logfmt"
    $ngSet = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
      -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName "ngrok-rdp" -Action $ngAct -Trigger (New-ScheduledTaskTrigger -AtStartup) `
      -Settings $ngSet -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName "ngrok-rdp"
    # Wait for the local agent API, then read the public endpoint.
    $ngEndpoint = $null
    for ($i = 0; $i -lt 40; $i++) {
      Start-Sleep 2
      try {
        $t = (Invoke-RestMethod "http://127.0.0.1:4040/api/tunnels").tunnels | Where-Object { $_.proto -eq "tcp" } | Select-Object -First 1
        if ($t.public_url) { $ngEndpoint = $t.public_url -replace '^tcp://', ''; break }
      } catch {}
    }
    if ($ngEndpoint) {
      try { Invoke-RestMethod -Method Put -Headers $h -Body "$ngEndpoint" "$md/guest-attributes/ngrok/endpoint" | Out-Null } catch {}
      Write-Output "rdp-startup: ngrok endpoint $ngEndpoint"
    } else {
      Write-Output "rdp-startup: ngrok no endpoint; diagnostics follow"
      Write-Output "rdp-startup: task state = $((Get-ScheduledTask -TaskName 'ngrok-rdp' -ErrorAction SilentlyContinue).State)"
      & $ngExe diagnose 2>&1 | Select-Object -First 5 | ForEach-Object { Write-Output "rdp-startup: diag: $_" }
      Get-Content $ngLog -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output "rdp-startup: nglog: $_" }
    }
  } else {
    Write-Output "rdp-startup: no ngrok-authtoken metadata; skipping ngrok relay"
  }
} catch { Write-Output "rdp-startup: ngrok setup failed: $($_.Exception.Message)" }

try {
  $code = Invoke-RestMethod -Headers $h "$md/attributes/rdp-unlock-watcher"
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
