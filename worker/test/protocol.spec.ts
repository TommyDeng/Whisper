import { describe, expect, it } from "vitest";
import { MAX_MESSAGE_CHARS, parseClientMessage } from "../src/protocol";

describe("parseClientMessage", () => {
  it("accepts a ping", () => {
    expect(parseClientMessage('{"type":"ping"}')).toEqual({
      ok: true,
      message: { type: "ping" },
    });
  });

  it("copies only the sdp field of an offer", () => {
    const parsed = parseClientMessage(
      JSON.stringify({ type: "signal", kind: "offer", sdp: "v=0", extra: "drop" }),
    );
    expect(parsed).toEqual({
      ok: true,
      message: { type: "signal", outbound: { type: "signal", kind: "offer", sdp: "v=0" } },
    });
  });

  it("rejects a candidate without a candidate line", () => {
    expect(parseClientMessage('{"type":"signal","kind":"candidate"}')).toMatchObject({
      ok: false,
      error: "candidate-required",
    });
  });

  it("rejects oversized payloads before they are useful", () => {
    const raw = `{"type":"ping","pad":"${"a".repeat(MAX_MESSAGE_CHARS)}"}`;
    expect(parseClientMessage(raw)).toMatchObject({ ok: false, error: "too-large" });
  });

  it("rejects invalid json", () => {
    expect(parseClientMessage("{")).toMatchObject({ ok: false, error: "invalid-json" });
  });
});
