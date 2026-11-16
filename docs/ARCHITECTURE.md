# How the RDP desktop is built

One Windows VM on Google Cloud, a small website on Vercel that turns it on and off, and scripts that keep it backed up and movable.

```
 Your PC / phone ──RDP (port 47231)──────────────▶  Windows VM "rdp-desktop" (Compute Engine)
        │                                              ├─ boot script  (vm/startup.ps1, from VM metadata)
        │ https                                        ├─ auto-suspend (vm/autosuspend.ps1, every 5 min)
        ▼                                              ├─ unlock watcher (vm/unlock-watcher.ps1)
 rdp-admin.vercel.app (Next.js) ──Compute API────▶     └─ disk: 250 GB, daily snapshots (rdp-daily)
   password login → status, start/stop/suspend/resume,
   .rdp download, Windows login, Unlock, Backups
```

## The website (`app/`, `lib/`, `proxy.ts`)

| Piece | What it does |
|---|---|
| `app/login/page.tsx`, `app/api/login` | One shared password (`APP_PASSWORD`). Wrong guesses wait 800 ms. A Vercel firewall rule allows 5 tries a minute. |
| `lib/session.ts` | A signed `rdp_session` cookie (jose, HS256, `SESSION_SECRET`), 30 days, HttpOnly, SameSite=Strict. Every POST also checks the `Origin` header. |
| `proxy.ts` | Sends visitors without a session cookie to `/login`. |
| `lib/gcp.ts` | All Google Cloud calls, made as the `rdp-website` service account (key in `GCP_SA_KEY_B64`, or Vercel OIDC → Workload Identity). It reads the VM, runs start/stop/suspend/resume, reads the RDP port the VM reports, requests an unlock, and lists or creates backups. It also works out the cost from the machine type. |
| `app/dashboard.tsx` | Status and buttons (polls every 3 s while the VM is changing state, every 20 s otherwise), connection details, the Windows login (`RDP_USERNAME`/`RDP_PASSWORD`), Unlock, and cost and timing details. |
| `app/backups.tsx`, `app/api/backups` | Lists the daily and manual snapshots and the newest bootable image; **Back up now** takes a snapshot. |
| `app/api/rdp` | A ready-made `.rdp` file using the VM's current IP and port. |

The website can only do what its custom roles allow:
- `rdpControl`, on the VM only: get, start, stop, suspend, resume, setMetadata, getGuestAttributes.
- `rdpBackup`, on the project: list and create snapshots, list images.

## The VM (`vm/`)

| Script | Runs | Purpose |
|---|---|---|
| `startup.ps1` | At every boot, as SYSTEM, from the `windows-startup-script-ps1` metadata | Puts RDP on the `rdp-port` metadata port and reports it (guest attribute `rdp/port`). Grows `C:` after a disk resize. Turns account lockout off and unlocks accounts. Logs failed and successful sign-ins to the serial port. Starts the unlock watcher. |
| `unlock-watcher.ps1` | Always, as SYSTEM | Waits for the `rdp-unlock` metadata key to change (the website's Unlock button), then unlocks every locked account. |
| `autosuspend.ps1` | Every 5 min, as SYSTEM | Suspends the VM after 30 minutes with no RDP connection and no Claude Code activity. |
| `setup-windows.ps1` | Once, by hand | Turns on suspend support, sets sessions never to log off, makes RDP smooth, and installs auto-suspend. |
| `tune-for-claude.ps1` | Once, by hand | Adds Defender exclusions, the High performance power plan and long paths. |
| `overnight.ps1` | When you start it | Runs Claude Code unattended through a `PLAN.md` file and suspends the VM when it finishes. |

## Backups and moving (`ops/`, `infra/`)

| Layer | Where it lives | How |
|---|---|---|
| Blueprint | `infra/rdp-desktop.json` in GitHub | `ops/export-blueprint.ps1`: machine, disk, port, firewall and roles. No secrets. |
| Whole disk | Snapshots in the EU multi-region | Daily schedule `rdp-daily` (kept 7 days), **Back up now** on the website, or `ops/backup.ps1` |
| Bootable copy | Image in family `rdp-desktop` | `ops/backup.ps1 -Image`; share it with `-ShareWith email` |
| Your files | `gs://PROJECT-rdp-backup/files` and a folder on your PC | `ops/backup.ps1 -Files -Download D:\rdp-backup`. A helper Linux VM mounts a snapshot read-only and syncs every user profile, `C:\work` and the RDP scripts. Bucket versioning keeps old versions for 30 days. |
| Secrets | Your PC only (`<Download>\secrets`) | `.env.local` holds the site password, the Windows password and the service-account key. Never on GitHub. |
| New account | Any project | `ops/restore.ps1 -Project NEW -Account EMAIL` copies the disk or image and rebuilds everything from the blueprint. It then repoints Vercel. |

Google's licence doesn't let its Windows Server images run outside Google Cloud. So the bootable copies stay in Google Cloud (any account), and the local copy holds your files rather than a bootable machine.
