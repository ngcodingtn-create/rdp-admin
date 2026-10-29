import { gcpErrorMessage, requestUnlock } from "@/lib/gcp";
import { isAuthed, sameOrigin } from "@/lib/session";

export const maxDuration = 30;

export async function POST(req: Request) {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  if (!sameOrigin(req)) return Response.json({ error: "Bad origin" }, { status: 403 });
  try {
    return Response.json(await requestUnlock());
  } catch (err) {
    return Response.json({ error: gcpErrorMessage(err) }, { status: 502 });
  }
}
