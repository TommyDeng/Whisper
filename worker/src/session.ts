import { DurableObject } from "cloudflare:workers";
import {
  isExpired,
  MAX_FRAME_CHARS,
  MAX_PAYLOAD_CHARS,
  MAX_QUEUED_PER_PEER,
  MESSAGE_ID,
  OFFLINE_TTL_MS,
  RATE_LIMIT_MAX_FRAMES,
  RATE_LIMIT_WINDOW_MS,
} from "./relay_limits";

type Peer = "a" | "b";

type QueueMessage = {
  id: string;
  payload: string;
  ts: number;
};

type Attachment = {
  peer: Peer;
  windowStart: number;
  count: number;
  replaced: boolean;
};

const COUNTER_PREFIX = "seq:";
const QUEUE_PREFIX = "q:";

function otherPeer(peer: Peer): Peer {
  return peer === "a" ? "b" : "a";
}

function sendJson(ws: WebSocket, value: Record<string, unknown>): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(JSON.stringify(value));
  } catch {
    // The socket may have closed between the readiness check and the send.
  }
}

function isQueueMessage(value: unknown): value is QueueMessage {
  if (!value || typeof value !== "object") return false;
  const record = value as Record<string, unknown>;
  return (
    typeof record.id === "string" &&
    typeof record.payload === "string" &&
    typeof record.ts === "number"
  );
}

function attachmentOf(ws: WebSocket): Attachment | null {
  const value = ws.deserializeAttachment();
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  const peer = record.peer;
  if (peer !== "a" && peer !== "b") return null;
  return {
    peer,
    windowStart: typeof record.windowStart === "number" ? record.windowStart : 0,
    count: typeof record.count === "number" ? record.count : 0,
    replaced: record.replaced === true,
  };
}

function allowFrame(ws: WebSocket): boolean {
  const current = attachmentOf(ws);
  if (!current) return false;

  const now = Date.now();
  let windowStart = current.windowStart;
  let count = current.count;
  if (now - windowStart >= RATE_LIMIT_WINDOW_MS) {
    windowStart = now;
    count = 0;
  }
  if (count >= RATE_LIMIT_MAX_FRAMES) return false;

  count += 1;
  ws.serializeAttachment({ ...current, windowStart, count });
  return true;
}

export class SessionDO extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const peerParam = url.searchParams.get("peer");
    if (peerParam !== "a" && peerParam !== "b") {
      return Response.json({ ok: false, error: "bad-peer" }, { status: 400 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const peer: Peer = peerParam;

    // The newest connection for a peer wins; mark the old one so its close
    // handler knows not to announce peer-offline.
    for (const ws of this.ctx.getWebSockets()) {
      const current = attachmentOf(ws);
      if (current && current.peer === peer && !current.replaced) {
        ws.serializeAttachment({ ...current, replaced: true });
        try {
          ws.close(4001, "replaced");
        } catch {
          // The socket may already be closing.
        }
      }
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server);

    const now = Date.now();
    server.serializeAttachment({ peer, windowStart: now, count: 0, replaced: false });

    const other = otherPeer(peer);
    const otherOnline = this.onlinePeers(other).length > 0;
    sendJson(server, { type: "welcome", peer, peerOnline: otherOnline });

    await this.purgeExpired(now);
    for (const queued of await this.unackedQueue(peer, now)) {
      sendJson(server, { type: "msg", id: queued.id, payload: queued.payload, ts: queued.ts });
    }

    if (otherOnline) {
      for (const ws of this.onlinePeers(other)) {
        sendJson(ws, { type: "peer-online" });
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // 每一帧都计入限速，包括格式错误的帧。
    if (!allowFrame(ws)) {
      sendJson(ws, { type: "error", error: "rate-limited" });
      return;
    }
    if (typeof message !== "string") {
      sendJson(ws, { type: "error", error: "invalid-json" });
      return;
    }
    if (message.length > MAX_FRAME_CHARS) {
      sendJson(ws, { type: "error", error: "too-large" });
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(message);
    } catch {
      sendJson(ws, { type: "error", error: "invalid-json" });
      return;
    }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      sendJson(ws, { type: "error", error: "expected-object" });
      return;
    }

    const record = parsed as Record<string, unknown>;
    const type = record.type;
    if (type !== "ping" && type !== "msg" && type !== "ack") {
      sendJson(ws, { type: "error", error: "unknown-type" });
      return;
    }


    if (type === "ping") {
      sendJson(ws, { type: "pong" });
      return;
    }

    const attachment = attachmentOf(ws);
    if (!attachment) return;
    const peer = attachment.peer;

    if (type === "ack") {
      const id = record.id;
      if (typeof id !== "string") {
        sendJson(ws, { type: "error", error: "bad-id" });
        return;
      }
      const removed = await this.deleteMessages(peer, id);
      if (removed) {
        await this.purgeExpired(Date.now());
        for (const target of this.onlinePeers(otherPeer(peer))) {
          sendJson(target, { type: "delivered", id });
        }
      }
      return;
    }

    const id = record.id;
    if (typeof id !== "string") {
      sendJson(ws, { type: "error", error: "bad-id" });
      return;
    }
    if (!MESSAGE_ID.test(id)) {
      sendJson(ws, { type: "error", error: "bad-id", id });
      return;
    }

    const payload = record.payload;
    if (typeof payload !== "string") {
      sendJson(ws, { type: "error", error: "bad-payload", id });
      return;
    }
    if (payload.length === 0) {
      sendJson(ws, { type: "error", error: "bad-payload", id });
      return;
    }
    if (payload.length > MAX_PAYLOAD_CHARS) {
      sendJson(ws, { type: "error", error: "too-large", id });
      return;
    }

    const now = Date.now();
    const other = otherPeer(peer);
    if (record.ephemeral === true) {
      const online = this.onlinePeers(other);
      if (online.length > 0) {
        for (const target of online) {
          sendJson(target, { type: "msg", id, payload, ts: now });
        }
      } else {
        sendJson(ws, { type: "dropped", id });
      }
      return;
    }

    await this.cleanExpired(now);
    const queued = await this.queueEntries(other, now);
    const duplicate = [...queued.values()].some((entry) => entry.id === id);
    if (duplicate) {
      sendJson(ws, { type: "stored", id });
      return;
    }
    if (queued.size >= MAX_QUEUED_PER_PEER) {
      sendJson(ws, { type: "error", error: "queue-full", id });
      return;
    }

    const seq = await this.nextSequence(other);
    await this.ctx.storage.put(this.queueKey(other, seq), { id, payload, ts: now });
    await this.scheduleAlarm();

    sendJson(ws, { type: "stored", id });
    for (const target of this.onlinePeers(other)) {
      sendJson(target, { type: "msg", id, payload, ts: now });
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    const attachment = attachmentOf(ws);
    if (!attachment || attachment.replaced) return;

    const stillConnected = this.onlinePeers(attachment.peer).some(
      (candidate) => candidate !== ws,
    );
    if (stillConnected) return;

    for (const target of this.onlinePeers(otherPeer(attachment.peer))) {
      sendJson(target, { type: "peer-offline" });
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, "error");
    } catch {
      // The socket may already be closing.
    }
  }

  async alarm(): Promise<void> {
    await this.purgeExpired(Date.now());
  }

  private onlinePeers(peer: Peer): WebSocket[] {
    return this.ctx.getWebSockets().filter((ws) => {
      const attachment = attachmentOf(ws);
      return (
        attachment !== null &&
        attachment.peer === peer &&
        !attachment.replaced &&
        ws.readyState === WebSocket.OPEN
      );
    });
  }

  private queueKey(peer: Peer, seq: number): string {
    return `${QUEUE_PREFIX}${peer}:${String(seq).padStart(12, "0")}`;
  }

  private async nextSequence(peer: Peer): Promise<number> {
    const key = `${COUNTER_PREFIX}${peer}`;
    const current = await this.ctx.storage.get<number>(key);
    const next = (typeof current === "number" && Number.isFinite(current) ? current : 0) + 1;
    await this.ctx.storage.put(key, next);
    return next;
  }

  private async queueEntries(peer: Peer, now: number): Promise<Map<string, QueueMessage>> {
    const entries = await this.ctx.storage.list<QueueMessage>({
      prefix: `${QUEUE_PREFIX}${peer}:`,
    });
    const result = new Map<string, QueueMessage>();
    for (const [key, value] of entries) {
      if (isQueueMessage(value) && !isExpired(value.ts, now)) {
        result.set(key, value);
      }
    }
    return result;
  }

  private async unackedQueue(peer: Peer, now: number): Promise<QueueMessage[]> {
    return [...(await this.queueEntries(peer, now)).values()];
  }

  private async deleteMessages(peer: Peer, id: string): Promise<boolean> {
    let deleted = false;
    const entries = await this.ctx.storage.list<QueueMessage>({
      prefix: `${QUEUE_PREFIX}${peer}:`,
    });
    for (const [key, value] of entries) {
      if (isQueueMessage(value) && value.id === id) {
        await this.ctx.storage.delete(key);
        deleted = true;
      }
    }
    return deleted;
  }

  private async cleanExpired(now: number): Promise<void> {
    const entries = await this.ctx.storage.list<QueueMessage>({ prefix: QUEUE_PREFIX });
    const deletions: Promise<unknown>[] = [];
    for (const [key, value] of entries) {
      if (isQueueMessage(value) && isExpired(value.ts, now)) {
        deletions.push(this.ctx.storage.delete(key));
      }
    }
    await Promise.all(deletions);
  }

  private async purgeExpired(now: number): Promise<void> {
    await this.cleanExpired(now);
    await this.scheduleAlarm();
  }

  private async scheduleAlarm(): Promise<void> {
    const entries = await this.ctx.storage.list<QueueMessage>({ prefix: QUEUE_PREFIX });
    let earliest = Infinity;
    for (const value of entries.values()) {
      if (isQueueMessage(value)) {
        earliest = Math.min(earliest, value.ts + OFFLINE_TTL_MS);
      }
    }
    if (Number.isFinite(earliest)) {
      await this.ctx.storage.setAlarm(earliest);
    } else {
      await this.ctx.storage.deleteAlarm();
    }
  }
}
