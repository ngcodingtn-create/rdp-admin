import { createBackup, gcpErrorMessage, listBackups } from "@/lib/gcp";
import { isAuthed, sameOrigin } from "@/lib/session";

export const dynamic = "force-dynamic";
export const maxDuration = 30;

export async function GET() {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  try {
    return Response.json(await listBackups(), { headers: { "Cache-Control": "no-store" } });
  } catch (err) {
    return Response.json({ error: gcpErrorMessage(err) }, { status: 502 });
  }
}

export async function POST(req: Request) {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  if (!sameOrigin(req)) return Response.json({ error: "Bad origin" }, { status: 403 });
  try {
    return Response.json(await createBackup());
  } catch (err) {
    return Response.json({ error: gcpErrorMessage(err) }, { status: 502 });
  }
}
