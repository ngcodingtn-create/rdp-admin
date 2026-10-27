import { NextResponse, type NextRequest } from "next/server";

// Convenience redirect only: every API route re-checks the session itself.
export function proxy(req: NextRequest) {
  if (!req.cookies.has("rdp_session")) {
    return NextResponse.redirect(new URL("/login", req.url));
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/"],
};
