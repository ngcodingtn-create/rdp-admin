# RDP Control: a cheap Windows cloud desktop that you turn on and off from a website

A Windows Server desktop on Google Cloud. A small website (hosted on Vercel) turns it on and off.
When you close it, the VM is **suspended**: RAM and every open app are saved to disk, like closing a laptop lid.
When you resume, your session is exactly as you left it, still signed in to everything. Most of the cost stops while it is suspended.

## Recommended setup and what it costs

| | Choice |
|---|---|
| OS | **Windows Server 2022 Datacenter** (`windows-2022`). Not 2025: Google lists "unable to resume when suspended" as a known issue for Server 2025. |
| Machine | **e2-highmem-2**: 2 vCPU, 16 GB RAM, us-central1 (Iowa) |
| Disk | **100 GB pd-balanced** (SSD) |
| IP | Ephemeral. It changes on each resume; the website always shows the current IP and builds the .rdp file for you |

Prices are for us-central1, checked 2026-10-27:

| Item | Rate |
|---|---|
| e2-highmem-2 compute | ~$0.090 / hour while running |
| Windows Server license | $0.046 / vCPU / hour → $0.092 / hour while running (**$0 while suspended or stopped**) |
| Disk 100 GB pd-balanced | $0.10 / GB-month → $10 / month, always |
| Saved RAM while suspended | $0.17 / GB-month → ~$2.72 / month for 16 GB if suspended all month |
| External IP | $0.005 / hour while running |
| Internet egress | first 1 GB free, then $0.12 / GB (RDP ≈ 0.05–0.2 GB/hour; more if you stream video) |

All-in, that is about **$0.19 per running hour** and **$0.36 per day** of fixed cost (disk plus saved RAM).

| Usage (22 weekdays + 8 weekend days) | Running hours | ≈ per month |
|---|---|---|
| Weekdays 4 h, weekends 10 h | 168 h | **~$44** |
| + Claude overnight, VM suspends as soon as it finishes (~3 h/night on average) | ~258 h | **~$60** |
| + Claude overnight, but the VM left on all night (8 h) | 408 h | ~$88 |
| Weekdays 8 h, weekends 10 h, overnight with auto-suspend | ~350 h | ~$77 |
| 24/7 (never turned off) | 730 h | ~$147 |

The Windows fee looks big in Google's calculator ($134/month for 4 vCPU) only because the calculator assumes 730 hours a month. It is charged per second while the VM runs.

Notes:
- **The free trial cannot run Windows.** Upgrade the billing account to paid; leftover credit still applies within its 90 days.
- Spot VMs aren't worth it. The Windows license isn't discounted, so you save only ~20%, and Google can kill the VM at any time and lose your open session.
- A suspended VM can stay suspended for up to 60 days. After that it becomes a normal stopped VM: files are kept, open apps are lost.

## Why you had to sign in again before, and why you won't now

Usual causes:
- the "free Google RDP" tricks (Cloud Shell, Colab, GitHub Actions + ngrok) give you a brand-new machine every time
- a VM that was deleted and recreated
- a Spot VM that was preempted
- a "full shutdown" that ends the Windows session

This setup fixes it in two layers:
1. **Suspend instead of stop.** RAM is kept, so Windows, your browser and your apps never restart.
2. **Disconnecting never logs you off.** Closing the RDP window only *disconnects*. `vm/setup-windows.ps1` sets the policies so a disconnected session is never ended and you always reconnect to the same session. Don't use Start → Sign out; just close the RDP window.

Even after a real shutdown, browser logins survive, because cookies live on the persistent disk. Only open windows are lost.

---

## Setup (about 30 minutes, once)

Run these commands in **Google Cloud Shell**: the `>_` button at the top right of console.cloud.google.com. It already has `gcloud`.

### 1. Project and APIs
```bash
export PROJECT=your-project-id
export ZONE=europe-west1-b   # Belgium: low latency from Europe / North Africa; us-central1-a is ~10% cheaper
export VM=rdp-desktop
gcloud config set project $PROJECT
gcloud services enable compute.googleapis.com iam.googleapis.com
```

### 2. Service accounts and minimal roles
Create two identities:
- one the **VM** uses to suspend itself when idle
- one the **website** uses to start, stop, suspend and resume it

```bash
gcloud iam service-accounts create rdp-vm-self --display-name="RDP VM (self-suspend)"
gcloud iam service-accounts create rdp-website --display-name="RDP control website"

gcloud iam roles create rdpSelfSuspend --project=$PROJECT --title="RDP self suspend" \
  --permissions=compute.instances.suspend
gcloud iam roles create rdpControl --project=$PROJECT --title="RDP control" \
  --permissions=compute.instances.get,compute.instances.start,compute.instances.stop,compute.instances.suspend,compute.instances.resume
```

### 3. Create the VM
```bash
gcloud compute instances create $VM --zone=$ZONE \
  --machine-type=e2-highmem-2 \
  --image-family=windows-2022 --image-project=windows-cloud \
  --boot-disk-size=100GB --boot-disk-type=pd-balanced \
  --service-account=rdp-vm-self@$PROJECT.iam.gserviceaccount.com --scopes=cloud-platform \
  --tags=rdp
```

### 4. Give each service account power over this one VM only
```bash
gcloud compute instances add-iam-policy-binding $VM --zone=$ZONE \
  --member="serviceAccount:rdp-vm-self@$PROJECT.iam.gserviceaccount.com" \
  --role="projects/$PROJECT/roles/rdpSelfSuspend"
gcloud compute instances add-iam-policy-binding $VM --zone=$ZONE \
  --member="serviceAccount:rdp-website@$PROJECT.iam.gserviceaccount.com" \
  --role="projects/$PROJECT/roles/rdpControl"
```
If `add-iam-policy-binding` isn't found, run the same commands with `gcloud beta compute ...`.

If **Start** or **Resume** later fails with an `iam.serviceAccounts.actAs` error, also run:
```bash
gcloud iam service-accounts add-iam-policy-binding rdp-vm-self@$PROJECT.iam.gserviceaccount.com \
  --member="serviceAccount:rdp-website@$PROJECT.iam.gserviceaccount.com" --role=roles/iam.serviceAccountUser
```

### 5. Firewall: RDP over TCP **and UDP**
UDP makes the mouse, scrolling and video much smoother. Restrict the rule to your own IP if your home IP is stable. Find it at `curl ifconfig.me`.
```bash
gcloud compute firewall-rules create allow-rdp-tcp-udp --network=default \
  --allow=tcp:3389,udp:3389 --target-tags=rdp --source-ranges=0.0.0.0/0
# Optional, tighter: --source-ranges=YOUR.HOME.IP/32
```
The default network may already have a `default-allow-rdp` rule open to the whole internet. If you restricted yours, delete that one:
`gcloud compute firewall-rules delete default-allow-rdp`

### 6. Create your Windows user
```bash
gcloud compute reset-windows-password $VM --zone=$ZONE --user=YOURNAME
```
Save the password it prints in your password manager.

### 7. One-time Windows setup (inside the VM)
1. Connect with Remote Desktop to the VM's IP as `YOURNAME`.
2. Copy the `vm` folder from this project to `C:\setup` in the VM. Copy/paste works over RDP.
3. Open **PowerShell as Administrator** and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\setup\setup-windows.ps1
   ```
4. Sign out once and back in, so every setting applies.
5. Install your apps and sign in to your accounts. From now on, **only close the RDP window. Never use Sign out.**

What the script does:
- **Suspend support:** turns hibernation off and stops the display from sleeping.
- **Sessions:** a disconnected session is never ended, and you always get your own session back.
- **Smoother RDP:** UDP transport, H.264/AVC 444 and 60 fps.
- **Desktop feel:** sound on, full visual effects, and no Server Manager window at sign-in.
- **Brute-force protection:** account lockout after 10 wrong passwords.
- **Auto-suspend:** installs a task that suspends the VM after 30 minutes with nobody connected **and Claude Code idle**, so forgetting it never costs a full night.
  - Claude counts as working while its session logs (`%USERPROFILE%\.claude\projects\**\*.jsonl`) keep changing. They change on every step, from the CLI or the desktop app's Code tab, so no hooks or other setup are needed.
  - To keep the VM on no matter what, create the file `C:\ProgramData\rdp-autosuspend\keepawake`. Delete it to go back to normal.
  - Log: `C:\ProgramData\rdp-autosuspend\log.txt`. The idle limit is `$IdleMinutes` in `autosuspend.ps1`.

**Test it:**
1. Open Notepad and type something.
2. Close the RDP window.
3. Click **Suspend** on the website and wait for "Suspended".
4. Click **Resume**.
5. Reconnect. Notepad should still be open with your text.

### 8. Credentials for the website (pick one)

**Option A: service-account key (simplest).** Works on a personal Gmail project with no organization.
```bash
gcloud iam service-accounts keys create key.json \
  --iam-account=rdp-website@$PROJECT.iam.gserviceaccount.com
base64 -w0 key.json   # copy this output into GCP_SA_KEY_B64
rm key.json
```
If key creation is blocked by an organization policy (`iam.managed.disableServiceAccountKeyCreation`), use option B.

**Option B: no stored key (Vercel OIDC → Workload Identity Federation).**

First, in Vercel: Project → Settings → Security, enable **OIDC Federation** in *Team* mode. Then:
```bash
export TEAM=your-vercel-team-slug VPROJECT=your-vercel-project-name
export NUM=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud services enable sts.googleapis.com iamcredentials.googleapis.com
gcloud iam workload-identity-pools create vercel --location=global
gcloud iam workload-identity-pools providers create-oidc vercel --location=global \
  --workload-identity-pool=vercel --issuer-uri="https://oidc.vercel.com/$TEAM" \
  --allowed-audiences="https://vercel.com/$TEAM" \
  --attribute-mapping="google.subject=assertion.sub" \
  --attribute-condition="assertion.sub=='owner:$TEAM:project:$VPROJECT:environment:production'"
gcloud iam service-accounts add-iam-policy-binding rdp-website@$PROJECT.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principal://iam.googleapis.com/projects/$NUM/locations/global/workloadIdentityPools/vercel/subject/owner:$TEAM:project:$VPROJECT:environment:production"
```
Then set `GCP_PROJECT_NUMBER`, `GCP_WORKLOAD_IDENTITY_POOL_ID=vercel`, `GCP_WORKLOAD_IDENTITY_POOL_PROVIDER_ID=vercel` and `GCP_SERVICE_ACCOUNT_EMAIL`. Option B only works on Vercel; for local dev use option A.

### 9. Deploy the website to Vercel
1. Push this folder to a **private** GitHub repo, then import it in Vercel. Or run `npx vercel` from this folder.
2. Add the environment variables from `.env.example`: `APP_PASSWORD`, `SESSION_SECRET`, `GCP_PROJECT_ID`, `GCE_ZONE`, `GCE_INSTANCE`, `RDP_USERNAME`, plus option A or B.
3. Set Node.js to 22.x or newer: Project → Settings → General.
4. Recommended: Vercel → Firewall → add a rate-limit rule on `/api/login`, for example 10 requests per minute.

Local dev: `copy .env.example .env.local`, fill it in, then run `npm install` and `npm run dev`.

### 10. Safety net for the bill
Billing → Budgets & alerts → create a budget, for example $50/month, with email alerts at 50/90/100%.

---

## Daily use
1. Open your website and click **Resume where I left off** (or **Start**). Wait for **Running**, usually under a minute.
2. Click **Download .rdp file** and open it. Everything is as you left it.
3. When done, **close the RDP window** (don't sign out), then click **Suspend** on the website.
   If you forget, the VM suspends itself after 30 minutes with nobody connected.

Use **Full shutdown** only for maintenance, such as changing the machine type or enlarging the disk. It closes all apps, but your files and browser logins stay on the disk.

**Saved RDP password:** the IP changes on each resume, so Windows may ask for the password again. Tick "Remember me", or use a password manager.
For zero prompts, reserve a static IP: `gcloud compute addresses create rdp-ip --region=us-central1`, then attach it to the VM. Static IPs are billed even while the VM is suspended (~$3.65–7.30/month).

## Letting Claude Code work while you sleep

The VM only runs the Claude Code program. The model runs on Anthropic's servers, so 2 vCPU / 16 GB is plenty, and a night of work costs about $0.19/hour *while Claude is actually working*. The overnight runner suspends the VM the moment the work is done.

**Setup per project:**
1. Add `PLAN.md` to the repo: a checklist of small, testable tasks (`- [ ] ...`). Small items work much better than one huge task.
2. Copy `C:\ProgramData\rdp-autosuspend\PROMPT.example.md` to the repo as `PROMPT.md`. Each round does the next item, runs the tests, commits, ticks the item, and writes `DONE` when everything is finished.
3. Work on a branch.

**Before bed:**
1. Run this in the VM (in a PowerShell window you leave open):
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\ProgramData\rdp-autosuspend\overnight.ps1 -Repo C:\work\myproject
   ```
2. Close the RDP window (don't sign out) and go to sleep.

**What it does:**
- Each round is a fresh `claude -p` run on **Sonnet** with `--permission-mode auto`. In auto mode a safety classifier blocks risky actions such as force-push, `reset --hard` and leaking secrets.
- A fresh context per round uses much less of your plan limit than one ever-growing session.
- It stops when any of these happens:
  - the plan is done (`DONE` exists)
  - 9 hours pass
  - the **weekly** limit is hit
  - 3 rounds in a row fail
- If the **5-hour** session limit is hit, it waits for the reset and continues. Waiting costs ~$0.18/hour, under $1 in the worst case, which is cheaper and simpler than suspending and resuming.
- At the end it suspends the VM right away.
- Options: `-Hours 6`, `-Model opus`, `-NoSuspend`. Logs go to `<repo>\.overnight\`.

**Making Max 5x last** (5-hour window + weekly cap, shared by every Claude chat, Claude Code session and subagent on your account):
- **Use Sonnet for routine and overnight work** (`/model sonnet`). Save Opus for hard design or debugging. It uses the limit much faster.
- **Keep context short.** Run `/clear` between unrelated tasks, because a long session resends its whole history every turn.
- **Don't run many sessions or agents at once.** They all draw from the same pool.
- **Check `/usage` before a night run.** If the weekly limit is nearly used up, the run will stop early.
- **You can run overnight work without the VM at all.** If the repo is on GitHub, Claude Code cloud sessions (`claude --cloud "task"` or claude.ai/code) and scheduled tasks (`/schedule`) run on Anthropic's machines while your VM stays suspended. They cost $0 on Google, but still count against your Claude limits. They're Linux-only, and scheduled tasks are a research preview.

## Project layout
```
app/
  page.tsx, dashboard.tsx    status card, buttons, IP, .rdp download
  login/page.tsx             password page
  api/login, api/logout      session cookie (signed JWT, HttpOnly, SameSite=Strict)
  api/vm                     GET status
  api/vm/[action]            POST start | stop | suspend | resume
  api/rdp                    GET .rdp file for the current IP
lib/gcp.ts                   Compute Engine REST calls + auth (key or OIDC)
lib/session.ts               password check and session cookie
proxy.ts                     redirects to /login when not signed in
vm/setup-windows.ps1         one-time Windows setup (run inside the VM)
vm/autosuspend.ps1           idle watcher installed by the setup script (-Now = suspend immediately)
vm/overnight.ps1             unattended Claude Code runner that suspends the VM when done
vm/PROMPT.example.md         per-round instructions for the overnight runner
```
