"use client";

import { useCallback, useEffect, useState } from "react";

type Vm = {
  name: string;
  status: string;
  machineType: string;
  cpus: number | null;
  memoryGb: number | null;
  diskGb: number | null;
  zone: string;
  project: string;
  ip: string | null;
  internalIp: string | null;
  cpuPlatform: string | null;
  createdAt: string | null;
  lastStart: string | null;
  lastStop: string | null;
  lastSuspend: string | null;
  hourly: number | null;
  suspendedDaily: number | null;
};

type Creds = { username: string | null; password: string | null };
type Action = "start" | "stop" | "suspend" | "resume";

const usd = (n: number | null | undefined) => (n == null ? "?" : `$${n.toFixed(2)}`);

const LABELS: Record<string, { text: string; tone: "ok" | "warn" | "off" | "sleep" }> = {
  RUNNING: { text: "Running", tone: "ok" },
  SUSPENDED: { text: "Suspended", tone: "sleep" },
  TERMINATED: { text: "Off", tone: "off" },
  STOPPED: { text: "Off", tone: "off" },
  SUSPENDING: { text: "Suspending…", tone: "warn" },
  STOPPING: { text: "Shutting down…", tone: "warn" },
  PENDING_STOP: { text: "Shutting down…", tone: "warn" },
  PROVISIONING: { text: "Starting…", tone: "warn" },
  STAGING: { text: "Starting…", tone: "warn" },
  REPAIRING: { text: "Repairing…", tone: "warn" },
};

const PENDING_TEXT: Record<Action, string> = {
  start: "Starting…",
  resume: "Resuming…",
  suspend: "Suspending…",
  stop: "Shutting down…",
};

const isBusy = (s: string) => LABELS[s]?.tone === "warn";

function ago(ts: string | null) {
  if (!ts) return "—";
  const mins = Math.max(0, Math.round((Date.now() - new Date(ts).getTime()) / 60000));
  if (mins < 60) return `${mins} min ago`;
  const h = Math.floor(mins / 60);
  if (h < 48) return `${h} h ${mins % 60} min ago`;
  return `${Math.floor(h / 24)} days ago`;
}

function hoursSince(ts: string | null) {
  return ts ? Math.max(0, (Date.now() - new Date(ts).getTime()) / 3600000) : 0;
}

function Copy({ value, label = "copy" }: { value: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      className="link"
      onClick={async () => {
        await navigator.clipboard.writeText(value);
        setDone(true);
        setTimeout(() => setDone(false), 1500);
      }}
    >
      {done ? "copied" : label}
    </button>
  );
}

export default function Dashboard() {
  const [vm, setVm] = useState<Vm | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Action | null>(null);
  const [creds, setCreds] = useState<Creds | null>(null);
  const [showPassword, setShowPassword] = useState(false);

  const refresh = useCallback(async () => {
    const res = await fetch("/api/vm", { cache: "no-store" });
    if (res.status === 401) {
      window.location.href = "/login";
      return;
    }
    const data = await res.json();
    if (!res.ok) {
      setError(data.error ?? "Could not read the VM status");
      return;
    }
    setVm(data);
    setError(null);
  }, []);

  // Poll fast while the VM is changing state, slowly otherwise.
  useEffect(() => {
    refresh();
    const fast = pending !== null || (vm && isBusy(vm.status));
    const id = setInterval(refresh, fast ? 3000 : 20000);
    return () => clearInterval(id);
  }, [refresh, pending, vm?.status]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetch("/api/credentials", { cache: "no-store" })
      .then((r) => (r.ok ? r.json() : null))
      .then(setCreds)
      .catch(() => setCreds(null));
  }, []);

  // Clear the pending flag once Google reports a transition.
  useEffect(() => {
    if (!pending || !vm) return;
    const target: Record<Action, string[]> = {
      start: ["PROVISIONING", "STAGING", "RUNNING"],
      resume: ["RUNNING"],
      suspend: ["SUSPENDING", "SUSPENDED"],
      stop: ["STOPPING", "PENDING_STOP", "TERMINATED", "STOPPED"],
    };
    if (target[pending].includes(vm.status)) setPending(null);
  }, [vm, pending]);

  async function act(action: Action) {
    if (
      action === "stop" &&
      !confirm("Full shutdown closes all your apps and windows. Use Suspend to keep them. Shut down anyway?")
    )
      return;
    setPending(action);
    setError(null);
    const res = await fetch(`/api/vm/${action}`, { method: "POST" });
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      setError(data.error ?? `Could not ${action} the VM`);
      setPending(null);
    }
    refresh();
  }

  async function logout() {
    await fetch("/api/logout", { method: "POST" });
    window.location.href = "/login";
  }

  const status = vm?.status ?? "";
  const label = LABELS[status] ?? { text: status || "Loading…", tone: "warn" as const };
  const running = status === "RUNNING";
  const off = status === "TERMINATED" || status === "STOPPED";
  const suspended = status === "SUSPENDED";
  const busy = pending !== null || isBusy(status);
  const address = vm?.ip ? `${vm.ip}:3389` : null;
  const sessionHours = running ? hoursSince(vm?.lastStart ?? null) : 0;
  const specs = [
    vm?.cpus && `${vm.cpus} vCPU`,
    vm?.memoryGb && `${vm.memoryGb} GB RAM`,
    vm?.diskGb && `${vm.diskGb} GB SSD`,
  ]
    .filter(Boolean)
    .join(" · ");

  return (
    <>
      <div className="card">
        <h1>{vm?.name ?? "Cloud desktop"}</h1>
        <p className="muted">{vm ? `Windows Server 2022 · ${vm.machineType}${specs ? ` · ${specs}` : ""}` : " "}</p>

        <div className="status">
          <span className={`dot ${pending ? "warn" : label.tone}`} />
          {pending ? PENDING_TEXT[pending] : label.text}
        </div>

        <div className="actions">
          {running && (
            <>
              <a className="btn primary" href="/api/rdp">
                Download .rdp file
              </a>
              <button disabled={busy} onClick={() => act("suspend")}>
                Suspend — keep everything open
              </button>
              <p className="hint">
                Like closing a laptop lid: apps and logins stay, the hourly charge stops. Close the RDP window first
                (don&apos;t sign out).
              </p>
              <button className="danger" disabled={busy} onClick={() => act("stop")}>
                Full shutdown
              </button>
            </>
          )}
          {suspended && (
            <button className="primary" disabled={busy} onClick={() => act("resume")}>
              Resume where I left off
            </button>
          )}
          {off && (
            <button className="primary" disabled={busy} onClick={() => act("start")}>
              Start
            </button>
          )}
          {busy && <p className="hint">This takes 30 seconds to a few minutes. The page updates on its own.</p>}
        </div>

        {error && <p className="error">{error}</p>}
      </div>

      <div className="card">
        <h2>Connection</h2>
        <dl className="meta">
          <dt>Address</dt>
          <dd>
            {address ?? "— (only while running)"} {address && <Copy value={address} />}
          </dd>
          <dt>Username</dt>
          <dd>
            {creds?.username ?? "— (set RDP_USERNAME)"} {creds?.username && <Copy value={creds.username} />}
          </dd>
          <dt>Password</dt>
          <dd>
            {creds?.password ? (
              <>
                <span className="mono">{showPassword ? creds.password : "••••••••••••"}</span>{" "}
                <button className="link" onClick={() => setShowPassword((s) => !s)}>
                  {showPassword ? "hide" : "show"}
                </button>{" "}
                <Copy value={creds.password} />
              </>
            ) : (
              "— (set RDP_PASSWORD)"
            )}
          </dd>
          <dt>Command</dt>
          <dd>
            {vm?.ip ? (
              <>
                <span className="mono">mstsc /v:{vm.ip}</span> <Copy value={`mstsc /v:${vm.ip}`} />
              </>
            ) : (
              "—"
            )}
          </dd>
        </dl>
        <p className="hint">
          On a phone or Mac use the Windows App (Microsoft Remote Desktop) with the address, username and password above.
        </p>
      </div>

      <div className="card">
        <h2>Details</h2>
        <dl className="meta">
          <dt>Status</dt>
          <dd>{status || "—"}</dd>
          {running && (
            <>
              <dt>Running since</dt>
              <dd>
                {ago(vm?.lastStart ?? null)} · ~{usd(vm?.hourly != null ? sessionHours * vm.hourly : null)} so far
              </dd>
            </>
          )}
          {suspended && (
            <>
              <dt>Suspended</dt>
              <dd>
                {ago(vm?.lastSuspend ?? null)} · ~{usd(vm?.suspendedDaily)}/day while suspended
              </dd>
            </>
          )}
          <dt>Cost</dt>
          <dd>
            ~{usd(vm?.hourly)}/h running · ~{usd(vm?.suspendedDaily)}/day suspended
          </dd>
          <dt>Auto-suspend</dt>
          <dd>after 30 min with no RDP and Claude idle</dd>
          <dt>Zone</dt>
          <dd>{vm?.zone ?? "—"}</dd>
          <dt>Project</dt>
          <dd>{vm?.project ?? "—"}</dd>
          <dt>Internal IP</dt>
          <dd>{vm?.internalIp ?? "—"}</dd>
          <dt>CPU platform</dt>
          <dd>{vm?.cpuPlatform ?? "—"}</dd>
          <dt>Created</dt>
          <dd>{vm?.createdAt ? new Date(vm.createdAt).toLocaleDateString() : "—"}</dd>
          <dt>Last suspended</dt>
          <dd>{ago(vm?.lastSuspend ?? null)}</dd>
          <dt>Last shut down</dt>
          <dd>{ago(vm?.lastStop ?? null)}</dd>
        </dl>
      </div>

      <footer>
        <span className="muted">Updates automatically</span>
        <button className="link" onClick={logout}>
          Sign out of this page
        </button>
      </footer>
    </>
  );
}
