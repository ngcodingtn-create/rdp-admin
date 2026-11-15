# Shared settings for the backup / restore scripts. Override any of them with environment variables,
# e.g.  $env:RDP_PROJECT = "my-new-project"  before running a script.

$Project = if ($env:RDP_PROJECT) { $env:RDP_PROJECT } else { "cohesive-bolt-510011-q3" }
$Zone    = if ($env:RDP_ZONE)    { $env:RDP_ZONE }    else { "europe-west1-b" }
$Vm      = if ($env:RDP_VM)      { $env:RDP_VM }      else { "rdp-desktop" }
$Region  = $Zone -replace '-[a-z]$', ''
$StorageLocation = "eu"                     # multi-region for snapshots/images: survives a regional outage
$Bucket  = "gs://$Project-rdp-backup"       # file-level backups (your folders), never the Windows system
$Family  = "rdp-desktop"                    # image family: "latest bootable copy" = newest image in it
$BlueprintPath = Join-Path $PSScriptRoot "..\infra\rdp-desktop.json"

$gcloud = (Get-Command gcloud.cmd -ErrorAction SilentlyContinue).Source
if (-not $gcloud) { $gcloud = "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd" }

# Runs gcloud and throws (with gcloud's error text) on failure. Avoid | % & ^ < > in arguments:
# gcloud.cmd goes through cmd.exe. stderr goes to a file because Windows PowerShell turns native
# stderr into terminating errors under $ErrorActionPreference = "Stop".
function G {
  $ErrorActionPreference = "Continue"
  $errFile = [IO.Path]::GetTempFileName()
  $out = & $gcloud @args 2>$errFile
  $code = $LASTEXITCODE
  $err = Get-Content $errFile -Raw; Remove-Item $errFile
  if ($code -ne 0) { throw "gcloud $($args -join ' ') failed: $err" }
  $out
}
# True when the gcloud command succeeds; never throws (for "does it exist?" checks and cleanup).
function GOk {
  $ErrorActionPreference = "Continue"
  & $gcloud @args 2>$null | Out-Null
  $LASTEXITCODE -eq 0
}
# Output of a gcloud command, or nothing if it fails; never throws (for polling).
function GTry {
  $ErrorActionPreference = "Continue"
  & $gcloud @args 2>$null
}
# Same, but returns parsed JSON (a list comes back as separate items, so wrap calls in @() for arrays).
function GJson {
  $o = (G @args --format=json) -join "`n" | ConvertFrom-Json
  $o
}

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Stamp { (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmm") }
