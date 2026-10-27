<#
  Control the cloud desktop from this PC (until the website is deployed, and as a backup after).

      .\pc\rdp.ps1 open      # start or resume, wait until it's up, then open Remote Desktop
      .\pc\rdp.ps1 close     # suspend: keeps every app open, stops the hourly charge
      .\pc\rdp.ps1 status
      .\pc\rdp.ps1 shutdown  # full shutdown (closes apps). Use only for maintenance.
#>
param([ValidateSet("open", "close", "status", "shutdown")][string]$Command = "status")

$Project = "cohesive-bolt-510011-q3"
$Zone = "europe-west1-b"
$Vm = "rdp-desktop"
$User = $env:RDP_USER   # optional: your Windows user name on the VM, pre-filled in the .rdp file

$gcloud = (Get-Command gcloud -ErrorAction SilentlyContinue).Source
if (-not $gcloud) { $gcloud = "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd" }
$common = @("--project=$Project", "--zone=$Zone", "--quiet")

function Get-Vm { & $gcloud compute instances describe $Vm @common --format=json 2>$null | ConvertFrom-Json }
function Wait-Status($want) {
  do { Start-Sleep 5; $s = (Get-Vm).status; Write-Host "  $s" } while ($s -notin $want)
}

$vm = Get-Vm
if (-not $vm) { throw "Could not read the VM. Run: gcloud auth login" }
$status = $vm.status

switch ($Command) {
  "status" {
    $ip = $vm.networkInterfaces[0].accessConfigs[0].natIP
    Write-Host "$Vm is $status$(if ($ip) { " at $ip" })"
  }
  "open" {
    if ($status -eq "SUSPENDED") { Write-Host "Resuming..."; & $gcloud compute instances resume $Vm @common | Out-Null }
    elseif ($status -in "TERMINATED", "STOPPED") { Write-Host "Starting..."; & $gcloud compute instances start $Vm @common | Out-Null }
    elseif ($status -ne "RUNNING") { Write-Host "Currently $status, waiting..."; Wait-Status @("RUNNING", "SUSPENDED", "TERMINATED") }
    Wait-Status @("RUNNING")
    $ip = (Get-Vm).networkInterfaces[0].accessConfigs[0].natIP

    # Wait until RDP answers (a few seconds after resume, ~1 min after a cold start).
    Write-Host "Waiting for Remote Desktop on $ip..."
    while (-not (Test-NetConnection $ip -Port 3389 -InformationLevel Quiet -WarningAction SilentlyContinue)) { Start-Sleep 3 }

    $rdp = Join-Path $env:TEMP "$Vm.rdp"
    @(
      "full address:s:$ip"
      if ($User) { "username:s:$User" }
      "screen mode id:i:2", "dynamic resolution:i:1", "smart sizing:i:1"
      "connection type:i:6", "networkautodetect:i:0", "bandwidthautodetect:i:1"
      "audiomode:i:0", "redirectclipboard:i:1", "autoreconnection enabled:i:1"
      "allow font smoothing:i:1", "allow desktop composition:i:1"
      "enablecredsspsupport:i:1", "prompt for credentials:i:0"
    ) | Set-Content -Path $rdp -Encoding ASCII
    Start-Process mstsc.exe $rdp
    Write-Host "Opened Remote Desktop to $ip"
  }
  "close" {
    if ($status -ne "RUNNING") { Write-Host "$Vm is $status; nothing to suspend."; break }
    Write-Host "Suspending (saving memory to disk, takes a minute or two)..."
    & $gcloud compute instances suspend $Vm @common | Out-Null
    Wait-Status @("SUSPENDED")
    Write-Host "Suspended. Only the disk and saved memory are billed now (~`$0.36/day)."
  }
  "shutdown" {
    if ($status -ne "RUNNING") { Write-Host "$Vm is $status."; break }
    & $gcloud compute instances stop $Vm @common | Out-Null
    Wait-Status @("TERMINATED", "STOPPED")
    Write-Host "Shut down."
  }
}
