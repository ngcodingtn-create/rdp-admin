<#
  Backs up the cloud desktop. Run on your PC (needs gcloud signed in to the account that owns the VM).

      .\ops\backup.ps1                                  # blueprint + snapshot of the whole disk (1-5 min)
      .\ops\backup.ps1 -Image                           # + a bootable image (what you move to another account)
      .\ops\backup.ps1 -Files -Download D:\rdp-backup   # + your folders synced to Cloud Storage and to this PC
      .\ops\backup.ps1 -Image -ShareWith new@gmail.com  # + let another Google account use the image

  What each layer is for:
    blueprint  infra\rdp-desktop.json in this repo: machine, disk, port, firewall, roles. No secrets.
    snapshot   the whole Windows disk, incremental, kept in the EU multi-region (also taken daily, see README).
    image      a bootable copy of the disk that another project/account can create a VM from (restore.ps1).
    files      every user profile, C:\work and the RDP scripts, synced to $Bucket and optionally to a local
               folder. Google-licensed Windows can't be run outside Google Cloud, so the local copy is your
               files, not a bootable machine.
    secrets    with -Download, .env.local (site password, Windows password, service-account key) is copied
               to <Download>\secrets. It never goes to GitHub.

  Snapshots are crash-consistent (like pulling the plug). For the cleanest copy, close your apps or use
  Full shutdown first. Manual snapshots and images are pruned to the newest -Keep of each.
#>
param(
  [switch]$Image,
  [switch]$Files,
  [string]$Download,
  [string]$ShareWith,
  [int]$Keep = 3
)

. "$PSScriptRoot\settings.ps1"
$ErrorActionPreference = "Stop"
if ($Download) { $Files = $true }
$stamp = Stamp
$name = "$Vm-$stamp"

$inst = GJson compute instances describe $Vm --zone=$Zone --project=$Project
$diskName = ($inst.disks | Where-Object boot).source.Split("/")[-1]
$disk = GJson compute disks describe $diskName --zone=$Zone --project=$Project

Step "Blueprint: infra\rdp-desktop.json"
& "$PSScriptRoot\export-blueprint.ps1"

Step "Snapshot $name of disk $diskName ($($disk.sizeGb) GB, VM is $($inst.status))"
G compute snapshots create $name --source-disk=$diskName --source-disk-zone=$Zone --project=$Project `
  --storage-location=$StorageLocation --labels=backup=manual --description="Manual backup of $Vm" | Out-Null
Write-Host "Snapshot ready"

if ($Image -or $ShareWith) {
  Step "Bootable image $name (family $Family)"
  $features = ($disk.guestOsFeatures.type) -join ","
  G compute images create $name --source-snapshot=$name --family=$Family --project=$Project `
    --storage-location=$StorageLocation --guest-os-features=$features --labels=backup=manual `
    --description="Bootable copy of $Vm from snapshot $name" | Out-Null
  $img = GJson compute images describe $name --project=$Project
  $lic = ($img.licenses | ForEach-Object { $_.Split("/")[-1] }) -join ", "
  Write-Host "Image ready: projects/$Project/global/images/$name  (Windows license: $(if ($lic) { $lic } else { 'MISSING' }))"
}

if ($ShareWith) {
  Step "Sharing image $name with $ShareWith"
  G compute images add-iam-policy-binding $name --project=$Project --member="user:$ShareWith" `
    --role=roles/compute.imageUser | Out-Null
  Write-Host "Done. In the new account run:  .\ops\restore.ps1 -Project NEW_PROJECT -SourceImage projects/$Project/global/images/$name"
}

if ($Files) {
  Step "Files: syncing your folders from snapshot $name to $Bucket/files"
  $helper = "$Vm-backup-helper"
  $vmSa = $inst.serviceAccounts[0].email

  # Private bucket with 30 days of old versions, so a deleted or overwritten file can still be recovered.
  if (-not (GOk storage buckets describe $Bucket --project=$Project)) {
    G storage buckets create $Bucket --project=$Project --location=EU --uniform-bucket-level-access `
      --public-access-prevention | Out-Null
    $life = Join-Path $env:TEMP "rdp-lifecycle.json"
    '{"rule":[{"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":30,"isLive":false}}]}' |
      Set-Content $life -Encoding ASCII
    G storage buckets update $Bucket --versioning --lifecycle-file=$life | Out-Null
  }
  G storage buckets add-iam-policy-binding $Bucket --member="serviceAccount:$vmSa" `
    --role=roles/storage.objectAdmin | Out-Null

  $destFile = Join-Path $env:TEMP "rdp-backup-dest.txt"
  [IO.File]::WriteAllText($destFile, "$Bucket/files")
  try {
    G compute disks create "$helper-src" --source-snapshot=$name --zone=$Zone --project=$Project --type=pd-standard | Out-Null
    G compute instances create $helper --zone=$Zone --project=$Project --machine-type=e2-standard-4 `
      --image-family=debian-12 --image-project=debian-cloud --boot-disk-size=20GB `
      --disk="name=$helper-src,device-name=src,mode=ro,auto-delete=yes" `
      --service-account=$vmSa --scopes=cloud-platform `
      --metadata=enable-guest-attributes=TRUE `
      --metadata-from-file="startup-script=$PSScriptRoot\files-helper.sh,dest=$destFile" | Out-Null

    $last = ""
    $deadline = (Get-Date).AddHours(6)
    do {
      Start-Sleep 20
      $s = GTry compute instances get-guest-attributes $helper --zone=$Zone --project=$Project `
        --query-path=backup/status --format="value(value)"
      if ($s -and $s -ne $last) { Write-Host "  $s"; $last = $s }
    } until ($s -match "^(done|failed)" -or (Get-Date) -gt $deadline)
    if ($s -notmatch "^done") { throw "File backup did not finish: $s (serial log: gcloud compute instances get-serial-port-output $helper)" }
  } finally {
    Write-Host "Removing the helper VM"
    GOk compute instances delete $helper --zone=$Zone --project=$Project --quiet | Out-Null
    GOk compute disks delete "$helper-src" --zone=$Zone --project=$Project --quiet | Out-Null
  }
}

if ($Download) {
  Step "Downloading to $Download (only changed files are transferred)"
  New-Item -ItemType Directory -Force -Path "$Download\files", "$Download\secrets" | Out-Null
  G storage rsync -r --delete-unmatched-destination-objects "$Bucket/files" "$Download\files"
  Copy-Item (Join-Path $PSScriptRoot "..\.env.local") "$Download\secrets\env.local" -ErrorAction SilentlyContinue
  Copy-Item $BlueprintPath "$Download\rdp-desktop.json"
  Write-Host "Local copy: $Download  (files\ = your folders, secrets\ = passwords and keys: keep it private)"
}

Step "Pruning: keep the newest $Keep manual snapshots and images"
$snaps = @(GJson compute snapshots list --project=$Project --filter=labels.backup=manual --sort-by=~creationTimestamp)
$snaps | Select-Object -Skip $Keep | ForEach-Object {
  # A snapshot still used by a kept image's source is fine to delete: images are independent copies.
  G compute snapshots delete $_.name --project=$Project --quiet | Out-Null; Write-Host "  deleted snapshot $($_.name)"
}
$imgs = @(GJson compute images list --project=$Project --no-standard-images --filter=family=$Family --sort-by=~creationTimestamp)
$imgs | Select-Object -Skip $Keep | ForEach-Object {
  G compute images delete $_.name --project=$Project --quiet | Out-Null; Write-Host "  deleted image $($_.name)"
}

Write-Host "`nBackup $name complete." -ForegroundColor Green
