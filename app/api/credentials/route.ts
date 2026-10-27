import { isAuthed } from "@/lib/session";

export const dynamic = "force-dynamic";

// The Windows login, fetched only when you click "Show" (never part of the regular status polling).
export async function GET() {
  if (!(await isAuthed())) return Response.json({ error: "Unauthorized" }, { status: 401 });
  return Response.json(
    {
      username: process.env.RDP_USERNAME ?? null,
      password: process.env.RDP_PASSWORD ?? null,
    },
    { headers: { "Cache-Control": "no-store" } },
  );
}
