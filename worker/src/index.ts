import { handleFileRequest } from "./files";
import { ROOM_CODE } from "./protocol";
import { INVITE_KEY, RELAY_ID, parseSessionAuth } from "./relay_limits";
import { authorizeSessionTurn } from "./session";
import { type TurnEnv, issueTurnCredentials } from "./turn";

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

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/turn-credentials") {
      const auth = parseSessionAuth(request);
      if (!auth) return bad("unauthorized", 401);
      const allowed = await authorizeSessionTurn(env.SESSIONS, auth.sessionId, auth.peer);
      if (!allowed.ok) return bad(allowed.error, allowed.status);
      const result = await issueTurnCredentials(env as unknown as TurnEnv);
      if (!result.ok) return bad(result.error, result.status);
      return Response.json(
        { ok: true, iceServers: result.iceServers },
        { headers: { "cache-control": "no-store" } },
      );
    }

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return Response.json(
        { ok: true, service: "whisper-relay" },
        { headers: { "cache-control": "no-store" } },
      );
    }

    const file = handleFileRequest(request, env, url);
    if (file) return file;

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
