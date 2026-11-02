export const ROOM_CODE = /^[A-Za-z0-9_-]{4,32}$/;

export const MAX_MESSAGE_CHARS = 256 * 1024;

export type SignalOutbound =
  | { type: "signal"; kind: "offer" | "answer"; sdp: string }
  | {
      type: "signal";
      kind: "candidate";
      candidate: string;
      sdpMid: string | null;
      sdpMLineIndex: number | null;
    }
  | { type: "signal"; kind: "bye" };

export type ClientMessage = { type: "ping" } | { type: "signal"; outbound: SignalOutbound };

export type ParseResult =
  | { ok: true; message: ClientMessage }
  | { ok: false; error: string };

export function parseClientMessage(raw: string): ParseResult {
  if (raw.length > MAX_MESSAGE_CHARS) {
    return { ok: false, error: "too-large" };
  }
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return { ok: false, error: "invalid-json" };
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "expected-object" };
  }
  const record = value as Record<string, unknown>;
  if (record.type === "ping") {
    return { ok: true, message: { type: "ping" } };
  }
  if (record.type !== "signal") {
    return { ok: false, error: "unknown-type" };
  }
  const kind = record.kind;
  if (kind === "bye") {
    return { ok: true, message: { type: "signal", outbound: { type: "signal", kind: "bye" } } };
  }
  if (kind === "offer" || kind === "answer") {
    if (typeof record.sdp !== "string" || record.sdp.length === 0) {
      return { ok: false, error: "sdp-required" };
    }
    return {
      ok: true,
      message: { type: "signal", outbound: { type: "signal", kind, sdp: record.sdp } },
    };
  }
  if (kind === "candidate") {
    if (typeof record.candidate !== "string") {
      return { ok: false, error: "candidate-required" };
    }
    const sdpMid = optionalString(record.sdpMid);
    if (sdpMid === undefined) {
      return { ok: false, error: "bad-sdp-mid" };
    }
    const sdpMLineIndex = optionalIndex(record.sdpMLineIndex);
    if (sdpMLineIndex === undefined) {
      return { ok: false, error: "bad-sdp-mline-index" };
    }
    return {
      ok: true,
      message: {
        type: "signal",
        outbound: {
          type: "signal",
          kind: "candidate",
          candidate: record.candidate,
          sdpMid,
          sdpMLineIndex,
        },
      },
    };
  }
  return { ok: false, error: "bad-signal-kind" };
}

function optionalString(value: unknown): string | null | undefined {
  if (value == null) return null;
  if (typeof value === "string") return value;
  return undefined;
}

function optionalIndex(value: unknown): number | null | undefined {
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) return undefined;
  return value;
}
