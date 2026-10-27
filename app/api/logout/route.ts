import { destroySession, sameOrigin } from "@/lib/session";

export async function POST(req: Request) {
  if (!sameOrigin(req)) return new Response("Bad origin", { status: 403 });
  await destroySession();
  return Response.json({ ok: true });
}
