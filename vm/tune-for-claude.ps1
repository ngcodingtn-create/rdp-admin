#Requires -RunAsAdministrator
<#
  Tunes the VM for several Claude Code sessions in parallel. Safe to run again any time.
  Run inside the VM, in an elevated PowerShell, from the folder holding the repo's vm\ scripts:

      powershell -ExecutionPolicy Bypass -File C:\setup\tune-for-claude.ps1 -WorkDir C:\work

  What it does:
    1. Stops Microsoft Defender from re-scanning every file Claude, Node, Git and builds touch
       (the main cause of 100% CPU on Windows dev boxes). Your code folder, ~\.claude and the npm/pip caches.
    2. Switches to the High performance power plan.
    3. Turns on long paths (deep node_modules trees) for Windows and Git.
    4. Updates the auto-suspend and overnight scripts to the parallel-safe versions next to this file.
#>
param([string]$WorkDir = "C:\work")

$ErrorActionPreference = "Stop"
function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Step "Defender: skip scanning code, caches and dev tools"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$paths = @($WorkDir) + (Get-ChildItem "C:\Users" -Directory | ForEach-Object {
    "$($_.FullName)\.claude", "$($_.FullName)\.local\bin", "$($_.FullName)\AppData\Local\npm-cache",
    "$($_.FullName)\AppData\Roaming\npm", "$($_.FullName)\AppData\Local\pip\cache", "$($_.FullName)\AppData\Local\Temp"
  })
$procs = "claude.exe", "node.exe", "git.exe", "rg.exe", "bash.exe", "npm.exe", "pnpm.exe", "python.exe", "uv.exe"
Add-MpPreference -ExclusionPath $paths -ExclusionProcess $procs
# Keep the weekly full scan from eating the CPU while you work.
Set-MpPreference -ScanAvgCPULoadFactor 20 -EnableLowCpuPriority $true
Write-Host "Excluded $($paths.Count) folders and $($procs.Count) programs"

Step "High performance power plan"
powercfg /setactive SCHEME_MIN

Step "Long paths for Windows and Git"
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null
if (Get-Command git -ErrorAction SilentlyContinue) { git config --system core.longpaths true }

Step "Updating the auto-suspend and overnight scripts"
$dir = "C:\ProgramData\rdp-autosuspend"
foreach ($f in "autosuspend.ps1", "overnight.ps1") {
  $src = Join-Path $PSScriptRoot $f
  if (Test-Path $src) { Copy-Item $src "$dir\$f" -Force; Write-Host "updated $f" } else { Write-Host "skipped $f (not next to this script)" }
}
Remove-Item "$dir\heartbeat" -ErrorAction SilentlyContinue  # the old single-runner heartbeat

Write-Host "`nDone. Put each project under $WorkDir so it stays excluded from scanning." -ForegroundColor Green
