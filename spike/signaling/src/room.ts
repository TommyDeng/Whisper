import { DurableObject } from "cloudflare:workers";
import { parseClientMessage } from "./protocol";

type Role = "offerer" | "answerer";

type Attachment = {
  id: string;
  role: Role;
  windowStart: number;
  count: number;
  closing?: boolean;
};

const RATE_WINDOW_MS = 10_000;
const RATE_LIMIT = 80;

function sendJson(ws: WebSocket, value: unknown): void {
  ws.send(JSON.stringify(value));
}

function peersExcept(all: WebSocket[], self: WebSocket): WebSocket[] {
  return all.filter((ws) => ws !== self && ws.readyState === WebSocket.OPEN);
}

export class RoomDO extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }

    const existing = this.ctx.getWebSockets();
    if (existing.length >= 2) {
      return Response.json({ ok: false, error: "room-full" }, { status: 409 });
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server);

    const requested = new URL(request.url).searchParams.get("role");
    const role = assignRole(existing, requested);
    const attachment: Attachment = {
      id: crypto.randomUUID(),
      role,
      windowStart: Date.now(),
      count: 0,
    };
    server.serializeAttachment(attachment);

    const peerCount = this.ctx.getWebSockets().length;
    sendJson(server, { type: "welcome", role, peerCount });
    if (peerCount === 2) {
      for (const peer of peersExcept(this.ctx.getWebSockets(), server)) {
        sendJson(peer, { type: "peer-joined", peerCount: 2 });
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") {
      sendJson(ws, { type: "error", error: "text-only" });
      return;
    }
    if (!allowMessage(ws)) {
      sendJson(ws, { type: "error", error: "rate-limited" });
      return;
    }
    const parsed = parseClientMessage(message);
    if (!parsed.ok) {
      sendJson(ws, { type: "error", error: parsed.error });
      return;
    }
    if (parsed.message.type === "ping") {
      sendJson(ws, { type: "pong" });
      return;
    }
    const payload = JSON.stringify(parsed.message.outbound);
    for (const peer of peersExcept(this.ctx.getWebSockets(), ws)) {
      peer.send(payload);
    }
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
    const current = attachmentOf(ws);
    if (current?.closing) return;
    if (current) {
      ws.serializeAttachment({ ...current, closing: true });
    }
    for (const peer of peersExcept(this.ctx.getWebSockets(), ws)) {
      sendJson(peer, { type: "peer-left", peerCount: 1 });
    }
    try {
      ws.close(code || 1000, reason || "closed");
    } catch {
      // The socket is already closing.
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, "error");
    } catch {
      // The socket is already closing.
    }
  }
}

export function assignRole(existing: WebSocket[], requested: string | null): Role {
  const hasOfferer = existing.some((ws) => attachmentOf(ws)?.role === "offerer");
  const hasAnswerer = existing.some((ws) => attachmentOf(ws)?.role === "answerer");
  if (requested === "offerer" && !hasOfferer) return "offerer";
  if (requested === "answerer" && !hasAnswerer) return "answerer";
  if (!hasOfferer) return "offerer";
  return "answerer";
}

function attachmentOf(ws: WebSocket): Attachment | null {
  const value = ws.deserializeAttachment();
  if (!value || typeof value !== "object") return null;
  const record = value as Partial<Attachment>;
  if ((record.role !== "offerer" && record.role !== "answerer") || typeof record.id !== "string") {
    return null;
  }
  return {
    id: record.id,
    role: record.role,
    windowStart: typeof record.windowStart === "number" ? record.windowStart : 0,
    count: typeof record.count === "number" ? record.count : 0,
    closing: record.closing === true,
  };
}

function allowMessage(ws: WebSocket): boolean {
  const current = attachmentOf(ws);
  if (!current) return false;
  const now = Date.now();
  let windowStart = current.windowStart;
  let count = current.count;
  if (now - windowStart >= RATE_WINDOW_MS) {
    windowStart = now;
    count = 0;
  }
  count += 1;
  ws.serializeAttachment({ ...current, windowStart, count });
  return count <= RATE_LIMIT;
}
