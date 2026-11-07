export const ROOM_CODE = /^[A-Za-z0-9_-]{4,32}$/;

export const MAX_MESSAGE_CHARS = 256 * 1024;

export type SignalOutbound =
  | { type: "signal"; kind: "offer"; sdp: string }
  | { type: "signal"; kind: "answer"; sdp: string }
  | {
      type: "signal";
      kind: "candidate";
      candidate: string;
      sdpMid: string | null;
      sdpMLineIndex: number | null;
    }
  | { type: "signal"; kind: "bye" }
  | { type: "signal"; kind: "ack"; id: string }
  | {
      type: "signal";
      kind: "file-start";
      id: string;
      name: string;
      size: number;
      chunkSize: number;
      chunks: number;
      sha256: string;
    }
  | {
      type: "signal";
      kind: "file-chunk";
      id: string;
      sequence: number;
      data: string; // base64 编码的加密文件块
    }
  | {
      type: "signal";
      kind: "file-end";
      id: string;
      sha256: string;
      submitMillis: number;
    };

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
  if (kind === "ack") {
    if (typeof record.id !== "string") {
      return { ok: false, error: "ack-id-required" };
    }
    return {
      ok: true,
      message: { type: "signal", outbound: { type: "signal", kind: "ack", id: record.id } },
    };
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
  if (kind === "file-start") {
    if (
      typeof record.id !== "string" ||
      typeof record.name !== "string" ||
      typeof record.size !== "number" ||
      typeof record.chunkSize !== "number" ||
      typeof record.chunks !== "number" ||
      typeof record.sha256 !== "string"
    ) {
      return { ok: false, error: "file-start-fields-required" };
    }
    return {
      ok: true,
      message: {
        type: "signal",
        outbound: {
          type: "signal",
          kind: "file-start",
          id: record.id,
          name: record.name,
          size: record.size,
          chunkSize: record.chunkSize,
          chunks: record.chunks,
          sha256: record.sha256,
        },
      },
    };
  }
  if (kind === "file-chunk") {
    if (
      typeof record.id !== "string" ||
      typeof record.sequence !== "number" ||
      typeof record.data !== "string"
    ) {
      return { ok: false, error: "file-chunk-fields-required" };
    }
    return {
      ok: true,
      message: {
        type: "signal",
        outbound: {
          type: "signal",
          kind: "file-chunk",
          id: record.id,
          sequence: record.sequence,
          data: record.data,
        },
      },
    };
  }
  if (kind === "file-end") {
    if (
      typeof record.id !== "string" ||
      typeof record.sha256 !== "string" ||
      typeof record.submitMillis !== "number"
    ) {
      return { ok: false, error: "file-end-fields-required" };
    }
    return {
      ok: true,
      message: {
        type: "signal",
        outbound: {
          type: "signal",
          kind: "file-end",
          id: record.id,
          sha256: record.sha256,
          submitMillis: record.submitMillis,
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
