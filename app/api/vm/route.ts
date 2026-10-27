import { gcpErrorMessage, getVm } from "@/lib/gcp";
import { isAuthed } from "@/lib/session";

export const dynamic = "force-dynamic";

export async function GET() {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  try {
    return Response.json(await getVm(), { headers: { "Cache-Control": "no-store" } });
  } catch (err) {
    return Response.json({ error: gcpErrorMessage(err) }, { status: 502 });
  }
}
