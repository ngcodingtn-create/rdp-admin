<#
  Unlocks locked-out Windows accounts the moment the website's "Unlock account" button is pressed.
  The button writes a new value to the VM's `rdp-unlock` metadata key; this script long-polls that key
  through the metadata server (no open ports, no credentials) and unlocks every locked local account.

  Installed and started at every boot by startup.ps1 (the VM's windows-startup-script-ps1) as the
  "RDP Unlock Watcher" scheduled task, running as SYSTEM. Survives suspend/resume.
  Log: C:\ProgramData\rdp-autosuspend\unlock.log
#>

$log = "C:\ProgramData\rdp-autosuspend\unlock.log"
$url = "http://metadata.google.internal/computeMetadata/v1/instance/attributes/rdp-unlock"
$h = @{ "Metadata-Flavor" = "Google" }

function Log($msg) { Add-Content -Path $log -Value "$((Get-Date).ToString('s'))  $msg" }

function Unlock-All($request) {
  $unlocked = @()
  foreach ($name in (Get-LocalUser | Where-Object Enabled).Name) {
    $u = [ADSI]"WinNT://$env:COMPUTERNAME/$name,user"
    if ($u.InvokeGet("IsAccountLocked")) {
      $u.InvokeSet("IsAccountLocked", $false)
      $u.CommitChanges()
      $unlocked += $name
      Log "Unlocked $name"
    }
  }
  # Report back through guest attributes (needs enable-guest-attributes=TRUE), readable with
  # gcloud compute instances get-guest-attributes rdp-desktop --query-path=rdp/
  try {
    $done = "$request handled $((Get-Date).ToString('s')); unlocked: $(if ($unlocked) { $unlocked -join ', ' } else { 'none were locked' })"
    Invoke-RestMethod -Method Put -Headers $h -Body $done `
      "http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/rdp/last-unlock" | Out-Null
  } catch {}
}

Log "Watcher started"
$last = $null   # the request value already handled; any new value means "unlock now"
$etag = $null
while ($true) {
  try {
    $q = if ($etag) { "?wait_for_change=true&timeout_sec=300&last_etag=$etag" } else { "" }
    $r = Invoke-WebRequest -UseBasicParsing -Headers $h -TimeoutSec 330 "$url$q"
    $etag = $r.Headers["ETag"]
    if ($null -ne $last -and $r.Content -ne $last) {
      Log "Unlock requested ($($r.Content))"
      Unlock-All $r.Content
    }
    $last = $r.Content
  } catch {
    # 404: nobody has pressed the button yet, so its first press counts as a change.
    # Anything else (e.g. the network right after a resume): retry; a press made meanwhile still differs from $last.
    if ($_.Exception.Response.StatusCode.value__ -eq 404) { $last = "" }
    $etag = $null
    Start-Sleep 20
  }
}
