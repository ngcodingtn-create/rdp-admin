<#
  Rebuilds the cloud desktop in another project, possibly owned by another Google account, from a copy of
  the old disk. The copy and everything after it is billed to the NEW project; the old project only needs
  to let the new account read the disk (see README: "Moving to another Google account").

      gcloud auth login                     # sign in with the NEW account (the old one stays signed in too)
      .\ops\restore.ps1 -Project new-project-id -Account new@gmail.com
      .\ops\restore.ps1 -Project new-project-id -Account new@gmail.com -Source projects/OLD/global/snapshots/NAME

  -Source is a disk, snapshot or image path. The default is the old VM's live disk from infra\rdp-desktop.json
  (stop the old VM first for the cleanest copy). Settings (machine type, disk size, RDP port, roles,
  firewall) come from infra\rdp-desktop.json. Windows, your apps, files and the Windows password come
  across unchanged because the whole disk is copied.
  At the end the website (Vercel) is pointed at the new project unless you pass -SkipWebsite.
#>
param(
  [Parameter(Mandatory)][string]$Project,
  [Parameter(Mandatory)][string]$Account,
  [string]$Source,
  [string]$Zone,
  [string]$MachineType,
  [string]$UseImage,      # an image already copied into -Project by an earlier run: skip the copy
  [switch]$SkipWebsite
)

. "$PSScriptRoot\settings.ps1"
# settings.ps1 sets the OLD project's defaults; the parameters given to this script win.
$Project = $PSBoundParameters["Project"]
$Zone = $PSBoundParameters["Zone"]
$ErrorActionPreference = "Stop"
$bp =Get-Content $BlueprintPath -Raw | ConvertFrom-Json
if (-not $Zone) { $Zone = $bp.zone }
if (-not $MachineType) { $MachineType = $bp.machineType }
if (-not $Source) { $Source = "projects/$($bp.project)/zones/$($bp.zone)/disks/$($bp.disk.name)" }
$Region = $Zone -replace '-[a-z]$', ''
$Vm = $bp.vm
# Every gcloud call below runs as the new account in the new project.
$env:CLOUDSDK_CORE_ACCOUNT = $Account
$env:CLOUDSDK_CORE_PROJECT = $Project

$vmSa = "rdp-vm-self@$Project.iam.gserviceaccount.com"
$siteSa = "rdp-website@$Project.iam.gserviceaccount.com"

Step "APIs"
G services enable compute.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com | Out-Null

if ($UseImage) {
  $img = $UseImage
} else {
  Step "Copying the disk into $Project as a bootable image (10-30 min for 250 GB)"
  $img = "$Vm-moved-$(Stamp)"
  $kind = if ($Source -match "/snapshots/") { "--source-snapshot" } elseif ($Source -match "/images/") { "--source-image-uri" } else { "--source-disk" }
  $srcArg = if ($kind -eq "--source-image-uri") { "https://www.googleapis.com/compute/v1/$Source" } else { $Source }
  # --async + polling: gcloud's own wait can give up on a copy this long.
  G compute images create $img "$kind=$srcArg" --force --family=$Family --storage-location=$StorageLocation `
    --guest-os-features=$($bp.disk.guestOsFeatures -join ',') --description="Moved from $Source" --async | Out-Null
  do { Start-Sleep 30; $st = (GJson compute images describe $img).status; Write-Host "  image $st" } while ($st -eq "PENDING")
  if ($st -ne "READY") { throw "Image copy ended as $st" }
}
$lic = (GJson compute images describe $img).licenses
Write-Host "Image $img ready (Windows license: $(if ($lic) { ($lic | ForEach-Object { $_.Split('/')[-1] }) -join ', ' } else { 'MISSING' }))"

Step "Service accounts and roles"
foreach ($sa in @(@("rdp-vm-self", "RDP VM (suspends itself)"), @("rdp-website", "RDP website"))) {
  if (-not (GOk iam service-accounts describe "$($sa[0])@$Project.iam.gserviceaccount.com")) {
    G iam service-accounts create $sa[0] --display-name=$($sa[1]) | Out-Null
  }
}
foreach ($r in $bp.customRoles.PSObject.Properties) {
  $perms = $r.Value -join ","
  if (GOk iam roles describe $r.Name --project=$Project) {
    G iam roles update $r.Name --project=$Project --permissions=$perms --quiet | Out-Null
  } else {
    G iam roles create $r.Name --project=$Project --title=$($r.Name) --permissions=$perms | Out-Null
  }
}

Step "Firewall: RDP on port $($bp.rdpPort)"
if (-not (GOk compute firewall-rules describe rdp-custom-port)) {
  G compute firewall-rules create rdp-custom-port --network=default --direction=INGRESS --action=ALLOW `
    --rules="tcp:$($bp.rdpPort),udp:$($bp.rdpPort)" --target-tags=rdp --source-ranges=0.0.0.0/0 | Out-Null
}
if (GOk compute firewall-rules describe default-allow-rdp) { G compute firewall-rules update default-allow-rdp --disabled | Out-Null }

Step "Creating VM $Vm ($MachineType) in $Zone"
$repo = Split-Path $PSScriptRoot
G compute instances create $Vm --zone=$Zone --machine-type=$MachineType --image=$img `
  --boot-disk-size="$($bp.disk.sizeGb)GB" --boot-disk-type=$($bp.disk.type) --tags=rdp `
  --service-account=$vmSa --scopes=cloud-platform `
  --metadata="enable-guest-attributes=TRUE,rdp-port=$($bp.rdpPort),rdp-unlock=init" `
  --metadata-from-file="windows-startup-script-ps1=$repo\vm\startup.ps1,rdp-unlock-watcher=$repo\vm\unlock-watcher.ps1" | Out-Null

Step "Permissions on the VM"
G compute instances add-iam-policy-binding $Vm --zone=$Zone --member="serviceAccount:$vmSa" --role="projects/$Project/roles/rdpSelfSuspend" | Out-Null
G compute instances add-iam-policy-binding $Vm --zone=$Zone --member="serviceAccount:$siteSa" --role="projects/$Project/roles/rdpControl" | Out-Null
G iam service-accounts add-iam-policy-binding $vmSa --member="serviceAccount:$siteSa" --role=roles/iam.serviceAccountUser | Out-Null
# The website's Backups card lists snapshots/images and can take a snapshot ("Back up now").
$backupPerms = "compute.snapshots.list,compute.snapshots.get,compute.snapshots.create,compute.snapshots.setLabels,compute.disks.createSnapshot,compute.images.list,compute.images.get"
if (-not (GOk iam roles describe rdpBackup --project=$Project)) {
  G iam roles create rdpBackup --project=$Project --title=rdpBackup --permissions=$backupPerms | Out-Null
}
G projects add-iam-policy-binding $Project --member="serviceAccount:$siteSa" --role="projects/$Project/roles/rdpBackup" --condition=None | Out-Null

Step "Daily snapshots (kept 7 days)"
if (-not (GOk compute resource-policies describe rdp-daily --region=$Region)) {
  G compute resource-policies create snapshot-schedule rdp-daily --region=$Region --max-retention-days=7 `
    --start-time=03:00 --daily-schedule --on-source-disk-delete=keep-auto-snapshots --storage-location=$StorageLocation | Out-Null
}
G compute disks add-resource-policies $Vm --resource-policies=rdp-daily --zone=$Zone | Out-Null

$ip = (GJson compute instances describe $Vm --zone=$Zone).networkInterfaces[0].accessConfigs[0].natIP

if (-not $SkipWebsite) {
  & "$PSScriptRoot\point-website.ps1" -Project $Project -Account $Account -Zone $Zone -Vm $Vm
}

Write-Host "`nDone. $Vm is running in $Project at ${ip}:$($bp.rdpPort) (first boot takes 2-3 minutes)." -ForegroundColor Green
Write-Host "Sign in with the same Windows user and password as before."
Write-Host "Then set `$env:RDP_PROJECT = '$Project' (or edit ops\settings.ps1 and pc\rdp.ps1) and run .\ops\export-blueprint.ps1."
