import { DurableObject } from "cloudflare:workers";
import {
  INVITE_KEY,
  INVITE_MAX_TTL_MS,
  INVITE_CLOCK_SKEW_MS,
  MAX_FRAME_CHARS,
  MAX_PAIR_PAYLOAD_CHARS,
  RATE_LIMIT_MAX_FRAMES,
  RATE_LIMIT_WINDOW_MS,
} from "./relay_limits";

type Role = "inviter" | "joiner";

type InviteRecord = {
  inviterKey: string;
  expiresAt: number;
  state: "open" | "requested" | "responded" | "done";
  joinerKey?: string;
  request?: string;
  response?: { accepted: boolean; payload: string };
};

type Attachment = {
  role: Role;
  key: string;
  windowStart: number;
  count: number;
  replaced?: boolean;
};

const INVITE_STORAGE_KEY = "invite";

function sendJson(ws: WebSocket, value: Record<string, unknown>): void {
  if (ws.readyState !== WebSocket.OPEN) return;
  try {
    ws.send(JSON.stringify(value));
  } catch {
    // The socket may have closed between the readiness check and the send.
  }
}

function attachmentOf(ws: WebSocket): Attachment | null {
  const value = ws.deserializeAttachment();
  if (!value || typeof value !== "object") return null;
  const record = value as Record<string, unknown>;
  const role = record.role;
  if (role !== "inviter" && role !== "joiner") return null;
  if (typeof record.key !== "string") return null;
  return {
    role,
    key: record.key,
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

/** 将 expires 查询参数解析为整数秒，非法则返回 null。 */
function parseExpires(value: string | null): number | null {
  if (value === null || !/^-?\d+$/.test(value)) return null;
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return n;
}

export class InviteDO extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const roleParam = url.searchParams.get("role");
    const keyParam = url.searchParams.get("key");

    if (roleParam !== "inviter" && roleParam !== "joiner") {
      return Response.json({ ok: false, error: "bad-role" }, { status: 400 });
    }
    if (!keyParam || !INVITE_KEY.test(keyParam)) {
      return Response.json({ ok: false, error: "bad-key" }, { status: 400 });
    }
    const role: Role = roleParam;
    const key = keyParam;

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }

    const now = Date.now();
    let stored = await this.ctx.storage.get<InviteRecord>(INVITE_STORAGE_KEY);
    let expired = false;

    if (stored && now >= stored.expiresAt) {
      await this.ctx.storage.deleteAll();
      expired = true;
      stored = undefined;
    }

    if (!stored) {
      if (role === "joiner") {
        return expired
          ? Response.json({ ok: false, error: "invite-expired" }, { status: 410 })
          : Response.json({ ok: false, error: "invite-not-found" }, { status: 404 });
      }
      // inviter registration
      const expiresSeconds = parseExpires(url.searchParams.get("expires"));
      if (expiresSeconds === null) {
        return Response.json({ ok: false, error: "bad-expiry" }, { status: 400 });
      }
      const expiresAt = expiresSeconds * 1000;
      if (!(now < expiresAt && expiresAt <= now + INVITE_MAX_TTL_MS + INVITE_CLOCK_SKEW_MS)) {
        return Response.json({ ok: false, error: "bad-expiry" }, { status: 400 });
      }
      stored = { inviterKey: key, expiresAt, state: "open" };
      await this.ctx.storage.put(INVITE_STORAGE_KEY, stored);
      await this.ctx.storage.setAlarm(expiresAt);
    } else {
      if (role === "inviter" && key !== stored.inviterKey) {
        return Response.json({ ok: false, error: "forbidden" }, { status: 403 });
      }
      if (stored.state === "done") {
        return Response.json({ ok: false, error: "invite-used" }, { status: 410 });
      }
      if (role === "joiner" && stored.joinerKey !== undefined && stored.joinerKey !== key) {
        return Response.json({ ok: false, error: "invite-used" }, { status: 410 });
      }
    }

    return this.acceptConnection(role, key, stored);
  }

  async alarm(): Promise<void> {
    this.closeAll(4002, "expired");
    await this.ctx.storage.deleteAll();
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
    if (
      type !== "ping" &&
      type !== "pair-request" &&
      type !== "pair-response" &&
      type !== "pair-done"
    ) {
      sendJson(ws, { type: "error", error: "unknown-type" });
      return;
    }
    if (type === "ping") {
      sendJson(ws, { type: "pong" });
      return;
    }

    const attachment = attachmentOf(ws);
    if (!attachment) return;
    const { role, key } = attachment;
    const stored = await this.ctx.storage.get<InviteRecord>(INVITE_STORAGE_KEY);
    if (!stored) return;

    if (type === "pair-request") {
      if (role !== "joiner") {
        sendJson(ws, { type: "error", error: "not-allowed" });
        return;
      }
      if (stored.state !== "open") {
        const bound = stored.joinerKey !== undefined && stored.joinerKey === key;
        if (!bound) {
          sendJson(ws, { type: "error", error: "invite-used" });
          try {
            ws.close(4003, "invite-used");
          } catch {
            // The socket may already be closing.
          }
          return;
        }
        sendJson(ws, { type: "error", error: "bad-state" });
        return;
      }
      const payload = record.payload;
      if (typeof payload !== "string" || payload.length === 0) {
        sendJson(ws, { type: "error", error: "bad-payload" });
        return;
      }
      if (payload.length > MAX_PAIR_PAYLOAD_CHARS) {
        sendJson(ws, { type: "error", error: "too-large" });
        return;
      }
      stored.joinerKey = key;
      stored.request = payload;
      stored.state = "requested";
      await this.ctx.storage.put(INVITE_STORAGE_KEY, stored);
      sendJson(ws, { type: "stored" });
      this.forwardTo("inviter", stored.inviterKey, { type: "pair-request", payload });
      return;
    }

    if (type === "pair-response") {
      if (role !== "inviter") {
        sendJson(ws, { type: "error", error: "not-allowed" });
        return;
      }
      if (stored.state !== "requested") {
        sendJson(ws, { type: "error", error: "bad-state" });
        return;
      }
      const payload = record.payload;
      if (typeof payload !== "string") {
        sendJson(ws, { type: "error", error: "bad-payload" });
        return;
      }
      if (payload.length > MAX_PAIR_PAYLOAD_CHARS) {
        sendJson(ws, { type: "error", error: "too-large" });
        return;
      }
      const accepted = record.accepted;
      if (typeof accepted !== "boolean") {
        sendJson(ws, { type: "error", error: "bad-accepted" });
        return;
      }
      stored.response = { accepted, payload };
      stored.state = "responded";
      await this.ctx.storage.put(INVITE_STORAGE_KEY, stored);
      sendJson(ws, { type: "stored" });
      const joinerKey = stored.joinerKey;
      if (joinerKey) {
        this.forwardTo("joiner", joinerKey, { type: "pair-response", accepted, payload });
      }
      return;
    }

    if (type === "pair-done") {
      if (role !== "joiner") {
        sendJson(ws, { type: "error", error: "not-allowed" });
        return;
      }
      if (stored.state !== "responded") {
        sendJson(ws, { type: "error", error: "bad-state" });
        return;
      }
      if (stored.joinerKey !== key) {
        sendJson(ws, { type: "error", error: "bad-state" });
        return;
      }
      stored.state = "done";
      delete stored.request;
      delete stored.response;
      await this.ctx.storage.put(INVITE_STORAGE_KEY, stored);
      this.forwardTo("inviter", stored.inviterKey, { type: "pair-done" });
      this.closeAll(1000, "done");
      return;
    }
  }

  private async acceptConnection(
    role: Role,
    key: string,
    current: InviteRecord
  ): Promise<Response> {
    // 同一角色同一 key 的旧连接被新连接替换（4001 replaced）。
    for (const ws of this.ctx.getWebSockets()) {
      const currentAttachment = attachmentOf(ws);
      if (
        currentAttachment &&
        currentAttachment.role === role &&
        currentAttachment.key === key &&
        currentAttachment.replaced !== true
      ) {
        ws.serializeAttachment({ ...currentAttachment, replaced: true });
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
    server.serializeAttachment({ role, key, windowStart: now, count: 0 });

    const record = current ?? (await this.ctx.storage.get<InviteRecord>(INVITE_STORAGE_KEY));
    if (!record) {
      return Response.json({ ok: false, error: "invite-not-found" }, { status: 404 });
    }
    sendJson(server, { type: "welcome", role, state: record.state });

    if (role === "inviter" && record.state === "requested" && record.request) {
      sendJson(server, { type: "pair-request", payload: record.request });
    }
    if (
      role === "joiner" &&
      record.joinerKey === key &&
      record.state === "responded" &&
      record.response
    ) {
      sendJson(server, {
        type: "pair-response",
        accepted: record.response.accepted,
        payload: record.response.payload,
      });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private forwardTo(targetRole: Role, targetKey: string, frame: Record<string, unknown>): void {
    const payload = JSON.stringify(frame);
    for (const ws of this.ctx.getWebSockets()) {
      const att = attachmentOf(ws);
      if (
        att &&
        att.role === targetRole &&
        att.key === targetKey &&
        ws.readyState === WebSocket.OPEN
      ) {
        try {
          ws.send(payload);
        } catch {
          // The socket may have closed between the check and the send.
        }
      }
    }
  }

  private closeAll(code: number, reason: string): void {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(code, reason);
      } catch {
        // The socket may already be closing.
      }
    }
  }
}
