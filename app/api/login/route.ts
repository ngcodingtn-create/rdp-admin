import { createSession, passwordMatches, sameOrigin } from "@/lib/session";

export async function POST(req: Request) {
  if (!sameOrigin(req)) return new Response("Bad origin", { status: 403 });
  const body = (await req.json().catch(() => ({}))) as { password?: unknown };
  if (!passwordMatches(body.password)) {
    // Slow down guessing a little; use Vercel WAF rate limiting for real protection.
    await new Promise((r) => setTimeout(r, 800));
    return Response.json({ error: "Wrong password" }, { status: 401 });
  }
  await createSession();
  return Response.json({ ok: true });
}
