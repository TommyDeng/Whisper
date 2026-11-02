import { ROOM_CODE } from "./protocol";

export { RoomDO } from "./room";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
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
