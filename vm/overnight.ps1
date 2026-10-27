<#
  Lets Claude Code work through a plan while you sleep, then suspends the VM as soon as it's done.

      powershell -ExecutionPolicy Bypass -File C:\ProgramData\rdp-autosuspend\overnight.ps1 -Repo C:\work\myproject

  The repo needs two files (see PROMPT.example.md):
    PLAN.md    a checklist of small tasks:  - [ ] add login page   - [ ] write tests for X ...
    PROMPT.md  the instructions each round: do the next unchecked item, test, commit, tick it; write DONE when all done

  Each round is a fresh `claude -p` run (fresh context = cheaper on your plan limits than one huge session).
  It stops when: DONE exists, the deadline passes, the weekly limit is hit, or 3 rounds in a row fail.
  On the 5-hour session limit it waits for the reset (the VM costs ~$0.18/h while waiting) and carries on.
  At the end it suspends the VM, unless you're connected over RDP or pass -NoSuspend.
  Logs: <repo>\.overnight\
#>
param(
  [Parameter(Mandatory)][string]$Repo,
  [double]$Hours = 9,
  [string]$Model = "sonnet",
  [int]$MaxRounds = 40,
  [int]$MaxTurnsPerRound = 150,
  [switch]$NoSuspend
)

$ErrorActionPreference = "Stop"
$dir = "C:\ProgramData\rdp-autosuspend"
$heartbeat = "$dir\heartbeat"
$claude = (Get-Command claude).Source
$deadline = (Get-Date).AddHours($Hours)

Set-Location $Repo
foreach ($f in "PLAN.md", "PROMPT.md") { if (-not (Test-Path $f)) { throw "$f not found in $Repo" } }
$logDir = Join-Path $Repo ".overnight"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# Keep the logs out of git so Claude never commits them.
if ((Test-Path ".git\info") -and -not (Select-String -Path ".git\info\exclude" -Pattern "^\.overnight/" -Quiet -ErrorAction SilentlyContinue)) {
  Add-Content ".git\info\exclude" ".overnight/"
}

function Log($msg) {
  $line = "$((Get-Date).ToString('s'))  $msg"
  Write-Host $line
  Add-Content (Join-Path $logDir "runner.log") $line
}
function Beat { if (-not (Test-Path $heartbeat)) { New-Item $heartbeat -ItemType File | Out-Null }; (Get-Item $heartbeat).LastWriteTime = Get-Date }
# Waits while keeping the VM marked busy, so auto-suspend doesn't kick in.
function Wait-Busy($minutes) { $until = (Get-Date).AddMinutes($minutes); while ((Get-Date) -lt $until -and (Get-Date) -lt $deadline) { Beat; Start-Sleep 60 } }

Log "Starting in $Repo with model $Model until $($deadline.ToString('HH:mm'))"
$round = 0
$failures = 0
$reason = "deadline reached"

while ($true) {
  if (Test-Path "DONE") { $reason = "plan finished (DONE file found)"; break }
  if ((Get-Date) -ge $deadline) { break }
  if ($round -ge $MaxRounds) { $reason = "max rounds reached"; break }
  $round++

  $out = Join-Path $logDir "round$round.log"
  $err = Join-Path $logDir "round$round.err"
  Log "Round $round"
  $p = Start-Process $claude -NoNewWindow -PassThru -RedirectStandardInput "PROMPT.md" `
    -RedirectStandardOutput $out -RedirectStandardError $err `
    -ArgumentList "-p", "--model", $Model, "--permission-mode", "auto", "--max-turns", $MaxTurnsPerRound
  while (-not $p.HasExited) {
    Beat
    if ((Get-Date) -ge $deadline) { Log "Deadline hit mid-round; stopping Claude"; taskkill /PID $p.Id /T /F | Out-Null; break }
    Start-Sleep 60
  }

  $text = ((Get-Content $out, $err -Raw -ErrorAction SilentlyContinue) -join "`n")
  if ($text -match "hit your .*(weekly|Opus|Sonnet|Fable)") { $reason = "weekly usage limit hit"; break }
  if ($text -match "hit your .*limit") {
    Log "5-hour usage limit hit; waiting for the reset (checking every 20 min)"
    Wait-Busy 20
    $round--   # the round didn't do any work; don't count it
    continue
  }
  if ($p.ExitCode -ne 0) {
    $failures++
    Log "Round $round exited with code $($p.ExitCode) ($failures in a row)"
    if ($failures -ge 3) { $reason = "3 failed rounds in a row (see $logDir)"; break }
  } else {
    $failures = 0
  }
}

Log "Stopping: $reason"
if ($NoSuspend) { Log "-NoSuspend given; leaving the VM on"; exit 0 }
Log "Asking the VM to suspend"
& "$dir\autosuspend.ps1" -Now
