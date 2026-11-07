import { ROOM_CODE } from "./protocol";

export { RoomDO } from "./room";

function issueTurnCredentials(env: Env) {
  const envAny = env as unknown as { TURN_URLS?: string; TURN_SECRET?: string };
  const turnUrls = (envAny.TURN_URLS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const turnSecret = envAny.TURN_SECRET ?? "";
  if (turnUrls.length === 0 || !turnSecret) {
    return null;
  }
  const now = Math.floor(Date.now() / 1000);
  const ttl = 86400;
  const expiry = now + ttl;
  const username = `${expiry}:turn-user`;
  const encoder = new TextEncoder();
  return crypto.subtle
    .importKey("raw", encoder.encode(turnSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"])
    .then((key) => crypto.subtle.sign("HMAC", key, encoder.encode(username)))
    .then((sig) => {
      const credential = btoa(String.fromCharCode(...new Uint8Array(sig)));
      return { username, credential, ttl, urls: turnUrls };
    });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/turn-credentials") {
      const creds = await issueTurnCredentials(env);
      if (!creds) {
        return Response.json(
          { ok: false, error: "TURN not configured: set TURN_URLS and TURN_SECRET environment variables" },
          { status: 501, headers: { "cache-control": "no-store" } },
        );
      }
      return Response.json(creds, { headers: { "cache-control": "no-store" } });
    }

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json(
        { ok: true, service: "whisper-webrtc-spike" },
        { headers: { "cache-control": "no-store" } },
      );
    }

    const match = /^\/ws\/([^/]+)$/.exec(url.pathname);
    if (!match) {
      return new Response("not found", { status: 404 });
    }

    let room: string;
    try {
      room = decodeURIComponent(match[1]);
    } catch {
      return Response.json({ ok: false, error: "bad-room-code" }, { status: 400 });
    }
    if (!ROOM_CODE.test(room)) {
      return Response.json({ ok: false, error: "bad-room-code" }, { status: 400 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }

    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
