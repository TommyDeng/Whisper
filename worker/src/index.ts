import { ROOM_CODE } from "./protocol";
import { INVITE_KEY, RELAY_ID } from "./relay_limits";

export { RoomDO } from "./room";
export { SessionDO } from "./session";
export { InviteDO } from "./invite";

function bad(error: string, status = 400): Response {
  return Response.json({ ok: false, error }, { status, headers: { "cache-control": "no-store" } });
}

/** 会话中继与配对的入口校验；通过后交给对应的 Durable Object。协议见 docs/relay-protocol.md。 */
function routeRelay(request: Request, env: Env, url: URL): Response | Promise<Response> | null {
  const match = /^\/(session|invite)\/([^/]+)$/.exec(url.pathname);
  if (!match) return null;
  const kind = match[1];
  const id = match[2];
  if (!RELAY_ID.test(id)) {
    return bad(kind === "session" ? "bad-session-id" : "bad-invite-id");
  }
  if (kind === "session") {
    const peer = url.searchParams.get("peer");
    if (peer !== "a" && peer !== "b") return bad("bad-peer");
  } else {
    const role = url.searchParams.get("role");
    if (role !== "inviter" && role !== "joiner") return bad("bad-role");
    if (!INVITE_KEY.test(url.searchParams.get("key") ?? "")) return bad("bad-key");
  }
  if (request.headers.get("Upgrade") !== "websocket") {
    return new Response("expected websocket", { status: 426 });
  }
  if (kind === "session") {
    return env.SESSIONS.get(env.SESSIONS.idFromName(id)).fetch(request);
  }
  return env.INVITES.get(env.INVITES.idFromName(id)).fetch(request);
}

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

    const relay = routeRelay(request, env, url);
    if (relay) return relay;

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
