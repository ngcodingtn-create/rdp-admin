"use client";

import { useCallback, useEffect, useState } from "react";

type Backup = { name: string; created: string; sizeGb: number | null; automatic: boolean; status: string };
type Backups = { snapshots: Backup[]; image: { name: string; created: string } | null };

const when = (ts: string) =>
  new Date(ts).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });

export default function BackupsCard() {
  const [data, setData] = useState<Backups | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [state, setState] = useState<"idle" | "sending" | "started">("idle");

  const refresh = useCallback(async () => {
    const res = await fetch("/api/backups", { cache: "no-store" });
    const body = await res.json().catch(() => ({}));
    if (res.ok) {
      setData(body);
      setError(null);
    } else setError(body.error ?? "Could not list backups");
  }, []);

  // Refresh often while a snapshot is being created, otherwise once a minute.
  const creating = data?.snapshots.some((s) => s.status !== "READY") || state === "started";
  useEffect(() => {
    refresh();
    const id = setInterval(refresh, creating ? 5000 : 60000);
    return () => clearInterval(id);
  }, [refresh, creating]);

  async function backUpNow() {
    setState("sending");
    const res = await fetch("/api/backups", { method: "POST" });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      setError(body.error ?? "Could not start the backup");
      setState("idle");
      return;
    }
    setState("started");
    refresh();
  }

  return (
    <div className="card">
      <h2>Backups</h2>
      <p className="hint">
        The whole Windows disk is saved automatically every day at 03:00 UTC and kept 7 days. Only changes are
        stored after the first copy.
      </p>
      <dl className="meta">
        {data?.snapshots.length ? (
          data.snapshots.map((s) => (
            <div key={s.name} style={{ display: "contents" }}>
              <dt>{s.automatic ? "Daily" : "Manual"}</dt>
              <dd>
                {when(s.created)}
                {s.status !== "READY" ? " · saving…" : s.sizeGb != null ? ` · ${s.sizeGb.toFixed(1)} GB` : ""}
              </dd>
            </div>
          ))
        ) : (
          <>
            <dt>Snapshots</dt>
            <dd>{data ? "none yet" : "…"}</dd>
          </>
        )}
        <dt>Bootable image</dt>
        <dd>{data?.image ? `${when(data.image.created)} · ${data.image.name}` : data ? "none yet" : "…"}</dd>
      </dl>
      <div className="actions">
        <button disabled={state === "sending"} onClick={backUpNow}>
          {state === "sending" ? "Starting…" : "Back up now"}
        </button>
        <p className="hint">
          {state === "started"
            ? "Backup started. It runs in Google Cloud and takes a few minutes; you can keep working or close this page."
            : "Takes a snapshot of the whole disk right now. For a copy of your files on your PC or a move to another account, use ops\\backup.ps1 (see README)."}
        </p>
      </div>
      {error && <p className="error">{error}</p>}
    </div>
  );
}
