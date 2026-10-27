"use client";

import { useCallback, useEffect, useState } from "react";

type Vm = {
  name: string;
  status: string;
  machineType: string;
  ip: string | null;
  lastStart: string | null;
  lastStop: string | null;
  lastSuspend: string | null;
};

type Action = "start" | "stop" | "suspend" | "resume";

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

const isBusy = (s: string) => LABELS[s]?.tone === "warn";

function since(ts: string | null) {
  if (!ts) return "—";
  const mins = Math.max(0, Math.round((Date.now() - new Date(ts).getTime()) / 60000));
  if (mins < 60) return `${mins} min ago`;
  const h = Math.floor(mins / 60);
  if (h < 48) return `${h} h ${mins % 60} min ago`;
  return `${Math.floor(h / 24)} days ago`;
}

export default function Dashboard() {
  const [vm, setVm] = useState<Vm | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, setPending] = useState<Action | null>(null);
  const [copied, setCopied] = useState(false);

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
    if (action === "stop" && !confirm("Full shutdown closes all your apps and windows. Use Suspend to keep them. Shut down anyway?")) return;
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

  async function copyIp() {
    if (!vm?.ip) return;
    await navigator.clipboard.writeText(vm.ip);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  const status = vm?.status ?? "";
  const label = LABELS[status] ?? { text: status || "Loading…", tone: "warn" as const };
  const running = status === "RUNNING";
  const off = status === "TERMINATED" || status === "STOPPED";
  const suspended = status === "SUSPENDED";
  const busy = pending !== null || isBusy(status);

  return (
    <>
      <div className="card">
        <h1>{vm?.name ?? "Cloud desktop"}</h1>
        <p className="muted">{vm?.machineType ?? " "}</p>

        <div className="status">
          <span className={`dot ${pending ? "warn" : label.tone}`} />
          {pending ? `${pending[0].toUpperCase()}${pending.slice(1)}ing…`.replace("Stoping", "Stopping") : label.text}
        </div>

        <dl className="meta">
          <dt>IP address</dt>
          <dd>
            {vm?.ip ?? "—"}{" "}
            {vm?.ip && (
              <button className="link" onClick={copyIp}>
                {copied ? "copied" : "copy"}
              </button>
            )}
          </dd>
          {running && (
            <>
              <dt>Running since</dt>
              <dd>{since(vm?.lastStart ?? null)}</dd>
            </>
          )}
          {suspended && (
            <>
              <dt>Suspended</dt>
              <dd>{since(vm?.lastSuspend ?? null)}</dd>
            </>
          )}
        </dl>

        <div className="actions">
          {running && (
            <>
              <a className="btn primary" href="/api/rdp">
                Download .rdp file
              </a>
              <button disabled={busy} onClick={() => act("suspend")}>
                Suspend — keep everything open
              </button>
              <p className="hint">Saves your session like closing a laptop lid. Stops the hourly Windows + CPU charge.</p>
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

      <footer>
        <span className="muted">Updates automatically</span>
        <button className="link" onClick={logout}>
          Sign out of this page
        </button>
      </footer>
    </>
  );
}
