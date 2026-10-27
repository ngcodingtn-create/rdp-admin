import { ACTIONS, gcpErrorMessage, runAction, type Action } from "@/lib/gcp";
import { isAuthed, sameOrigin } from "@/lib/session";

export const maxDuration = 30;

export async function POST(req: Request, { params }: { params: Promise<{ action: string }> }) {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  if (!sameOrigin(req)) return Response.json({ error: "Bad origin" }, { status: 403 });

  const { action } = await params;
  if (!ACTIONS.includes(action as Action)) {
    return Response.json({ error: "Unknown action" }, { status: 400 });
  }
  try {
    return Response.json(await runAction(action as Action));
  } catch (err) {
    return Response.json({ error: gcpErrorMessage(err) }, { status: 502 });
  }
}
