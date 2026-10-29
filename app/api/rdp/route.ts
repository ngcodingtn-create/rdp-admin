import { gcpErrorMessage, getVm } from "@/lib/gcp";
import { isAuthed } from "@/lib/session";

export const dynamic = "force-dynamic";

// Downloads a ready-to-use .rdp file pointing at the VM's current IP.
// The password is never put in the file: Windows saves it in Credential Manager
// the first time you tick "Remember me".
export async function GET() {
  if (!(await isAuthed())) return new Response("Unauthorized", { status: 401 });

  let ip: string | null;
  let port: number;
  try {
    ({ ip, rdpPort: port } = await getVm());
  } catch (err) {
    return new Response(gcpErrorMessage(err), { status: 502 });
  }
  if (!ip) return new Response("The VM has no external IP right now (is it running?)", { status: 409 });

  const lines = [
    `full address:s:${port === 3389 ? ip : `${ip}:${port}`}`,
    process.env.RDP_USERNAME ? `username:s:${process.env.RDP_USERNAME}` : null,
    "screen mode id:i:2",
    "use multimon:i:0",
    "dynamic resolution:i:1",
    "smart sizing:i:1",
    "connection type:i:6", // LAN quality: full visuals
    "networkautodetect:i:0",
    "bandwidthautodetect:i:1",
    "audiomode:i:0", // play sound on this computer
    "redirectclipboard:i:1",
    "autoreconnection enabled:i:1",
    "allow font smoothing:i:1",
    "allow desktop composition:i:1",
    "disable wallpaper:i:0",
    "disable full window drag:i:0",
    "disable menu anims:i:0",
    "disable themes:i:0",
    "enablecredsspsupport:i:1",
    "prompt for credentials:i:0",
  ].filter(Boolean);

  const name = (process.env.GCE_INSTANCE ?? "vm").replace(/[^\w-]/g, "");
  return new Response(lines.join("\r\n") + "\r\n", {
    headers: {
      "Content-Type": "application/x-rdp",
      "Content-Disposition": `attachment; filename="${name}.rdp"`,
      "Cache-Control": "no-store",
    },
  });
}
