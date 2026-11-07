import { DurableObject } from "cloudflare:workers";
import { parseClientMessage, type SignalOutbound } from "./protocol";

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

// 离线消息最长保留 7 天（秒）
const OFFLINE_MSG_TTL_SECONDS = 7 * 24 * 60 * 60; // 604800

// 单条离线消息最大 256 KiB
const MAX_OFFLINE_MSG_BYTES = 256 * 1024;

// 每个会话离线消息最大条数
const MAX_OFFLINE_MSGS_PER_ROOM = 1000;

function sendJson(ws: WebSocket, value: unknown): void {
  ws.send(JSON.stringify(value));
}

function peersExcept(all: WebSocket[], self: WebSocket): WebSocket[] {
  return all.filter((ws) => ws !== self && ws.readyState === WebSocket.OPEN);
}

type OfflineMessage = {
  id: string;
  from: string;
  payload: string; // JSON 字符串的 E2EE 密文消息
  timestamp: number;
};

export class RoomDO extends DurableObject<Env> {
  // TURN 中继流量统计（本 DO 实例的 WebSocket 消息字节数）
  turnBytes = 0;

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // 非 WebSocket 请求：处理 TURN 用量查询
    if (request.method === "GET" && url.pathname === "/turn-usage") {
      return Response.json(
        { ok: true, room: this.ctx.id.toString(), turnBytes: this.turnBytes },
        { headers: { "cache-control": "no-store" } },
      );
    }

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

    // 新加入的客户端：拉取并发送所有离线消息
    const offlineMsgs = await this.getOfflineMessages();
    for (const msg of offlineMsgs) {
      try {
        server.send(msg.payload);
        this.turnBytes += new TextEncoder().encode(msg.payload).byteLength;
      } catch {
        // 发送失败忽略
      }
    }
    // 发送完离线消息后，删除已发送的
    for (const msg of offlineMsgs) {
      await this.ctx.storage.delete(`msg:${msg.id}`);
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
    const { message: msg } = parsed;

    if (msg.type === "ping") {
      sendJson(ws, { type: "pong" });
      return;
    }

    if (msg.type !== "signal") {
      sendJson(ws, { type: "error", error: "unsupported-message-type" });
      return;
    }

    const outbound = msg.outbound as { kind: string; [key: string]: unknown };
    const kind = outbound.kind;

    // 处理 ACK：删除对应的离线消息
    if (kind === "ack") {
      const msgId = (outbound as { id?: string }).id;
      if (msgId) {
        await this.ctx.storage.delete(`msg:${msgId}`);
      }
      return;
    }

    // 处理文件传输消息（文件块较大，做额外大小检查）
    const payload = JSON.stringify(outbound);
    if (
      (kind === "file-chunk" || kind === "file-start" || kind === "file-end") &&
      new TextEncoder().encode(payload).byteLength > MAX_OFFLINE_MSG_BYTES
    ) {
      sendJson(ws, { type: "error", error: "message-too-large" });
      return;
    }

    const peers = peersExcept(this.ctx.getWebSockets(), ws);

    // 统计消息字节数作为 TURN 中继流量（所有通过 DO 的消息都经过中继）
    this.turnBytes += new TextEncoder().encode(message).byteLength;

    // 如果对方在线，直接转发
    if (peers.length > 0) {
      for (const peer of peers) {
        peer.send(payload);
      }
      return;
    }

    // 对方离线，将密文存入 DO 存储（离线队列）
    const senderId = attachmentOf(ws)?.id ?? crypto.randomUUID();
    await this.storeOfflineMessage(outbound, senderId);
    sendJson(ws, {
      type: "ack",
      id: (outbound as { id?: string }).id ?? crypto.randomUUID(),
    });
  }

  /// 将一条离线密文消息持久化到 DO 存储，7 天后自动过期。
  private async storeOfflineMessage(
    outbound: Record<string, unknown>,
    fromAttachmentId: string
  ): Promise<void> {
    const id = (outbound as { id?: string }).id ?? crypto.randomUUID();
    const now = Date.now();

    const msg: OfflineMessage = {
      id,
      from: fromAttachmentId,
      payload: JSON.stringify(outbound),
      timestamp: now,
    };

    // 清理过期消息（每次写入时轻量清理）
    await this.purgeExpiredMessages();

    // 如果离线消息过多，删除最旧的一条
    const existing = Array.from(await this.ctx.storage.list<OfflineMessage>({ prefix: "msg:" }));
    if (existing.length >= MAX_OFFLINE_MSGS_PER_ROOM) {
      const oldest = existing.sort((a, b) => a[0].localeCompare(b[0]))[0];
      if (oldest) {
        await this.ctx.storage.delete(oldest[0]);
      }
    }

    await this.ctx.storage.put(`msg:${id}`, msg);
  }

  /// 删除 7 天前的过期离线消息。
  private async purgeExpiredMessages(): Promise<void> {
    const cutoff = Date.now() - OFFLINE_MSG_TTL_SECONDS;
    const list = Array.from(await this.ctx.storage.list<OfflineMessage>({ prefix: "msg:" }));
    const deletions: Promise<unknown>[] = [];
    for (const key of list.slice(0, 50)) {
      const stored = key[1];
      if (stored && stored.timestamp < cutoff) {
        deletions.push(this.ctx.storage.delete(key[0]));
      }
    }
    if (deletions.length > 0) {
      await Promise.all(deletions);
    }
  }

  /// 获取当前所有离线消息（对方上线时拉取）。
  private async getOfflineMessages(): Promise<OfflineMessage[]> {
    await this.purgeExpiredMessages();
    const list = Array.from(await this.ctx.storage.list<OfflineMessage>({ prefix: "msg:" }));
    const msgs: OfflineMessage[] = [];
    for (const key of list) {
      const stored = key[1];
      if (stored) msgs.push(stored);
    }
    return msgs.sort((a, b) => a.timestamp - b.timestamp);
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
