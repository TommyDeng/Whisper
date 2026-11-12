import { exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";

function room(): string {
  return `r${crypto.randomUUID().replaceAll("-", "").slice(0, 12)}`;
}

function nextMessage(ws: WebSocket): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timed out waiting for signaling message")), 4000);
    const onMessage = (event: MessageEvent): void => {
      clearTimeout(timer);
      ws.removeEventListener("message", onMessage);
      resolve(JSON.parse(String(event.data)) as Record<string, unknown>);
    };
    ws.addEventListener("message", onMessage);
  });
}

async function open(
  code: string,
  role?: "offerer" | "answerer",
): Promise<{ ws: WebSocket; welcome: Record<string, unknown> }> {
  const query = role ? `?role=${role}` : "";
  const response = await exports.default.fetch(`http://example.com/ws/${code}${query}`, {
    headers: { Upgrade: "websocket" },
  });
  if (response.status !== 101 || !response.webSocket) {
    throw new Error(`upgrade failed: ${response.status} ${await response.text()}`);
  }
  const ws = response.webSocket;
  const welcomePromise = nextMessage(ws);
  ws.accept();
  return { ws, welcome: await welcomePromise };
}

describe("signaling relay", () => {
  it("answers health checks without a room", async () => {
    const response = await exports.default.fetch("http://example.com/health");
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      ok: true,
      service: "whisper-relay",
    });
  });

  it("rejects bad paths, short room codes, and non-websocket upgrades", async () => {
    expect((await exports.default.fetch("http://example.com/nope")).status).toBe(404);
    expect((await exports.default.fetch("http://example.com/ws/ab")).status).toBe(400);
    const notWs = await exports.default.fetch("http://example.com/ws/roomok");
    expect(notWs.status).toBe(426);
  });

  it("assigns roles, relays one signal, and tells the other peer about leave", async () => {
    const code = room();
    const offerer = await open(code);
    expect(offerer.welcome).toEqual({ type: "welcome", role: "offerer", peerCount: 1 });

    const joined = nextMessage(offerer.ws);
    const answerer = await open(code);
    expect(answerer.welcome).toEqual({ type: "welcome", role: "answerer", peerCount: 2 });
    expect(await joined).toEqual({ type: "peer-joined", peerCount: 2 });

    const relayed = nextMessage(answerer.ws);
    offerer.ws.send(
      JSON.stringify({
        type: "signal",
        kind: "candidate",
        candidate: "candidate:1 1 UDP 1 192.168.1.5 9 typ host",
        sdpMid: "0",
        sdpMLineIndex: 0,
        note: "not forwarded",
      }),
    );
    expect(await relayed).toEqual({
      type: "signal",
      kind: "candidate",
      candidate: "candidate:1 1 UDP 1 192.168.1.5 9 typ host",
      sdpMid: "0",
      sdpMLineIndex: 0,
    });

    const left = nextMessage(answerer.ws);
    offerer.ws.close(1000, "done");
    expect(await left).toEqual({ type: "peer-left", peerCount: 1 });
    answerer.ws.close(1000, "done");
  });

  it("lets SPIKE_ROLE override join order", async () => {
    const code = room();
    const first = await open(code, "answerer");
    expect(first.welcome).toEqual({ type: "welcome", role: "answerer", peerCount: 1 });
    const joined = nextMessage(first.ws);
    const second = await open(code, "offerer");
    expect(second.welcome).toEqual({ type: "welcome", role: "offerer", peerCount: 2 });
    expect(await joined).toEqual({ type: "peer-joined", peerCount: 2 });
    first.ws.close();
    second.ws.close();
  });

  it("refuses a third peer", async () => {
    const code = room();
    const first = await open(code);
    const second = await open(code);
    const third = await exports.default.fetch(`http://example.com/ws/${code}`, {
      headers: { Upgrade: "websocket" },
    });
    expect(third.status).toBe(409);
    await expect(third.json()).resolves.toMatchObject({ error: "room-full" });
    first.ws.close();
    second.ws.close();
  });

  it("does not relay between different room codes", async () => {
    const a = await open(room());
    const b = await open(room());
    let leaked = 0;
    b.ws.addEventListener("message", () => {
      leaked += 1;
    });
    a.ws.send(JSON.stringify({ type: "signal", kind: "bye" }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(leaked).toBe(0);
    a.ws.close();
    b.ws.close();
  });

  it("returns an error for invalid payloads and pongs a ping", async () => {
    const peer = await open(room());
    const pong = nextMessage(peer.ws);
    peer.ws.send(JSON.stringify({ type: "ping" }));
    expect(await pong).toEqual({ type: "pong" });
    const error = nextMessage(peer.ws);
    peer.ws.send("{");
    expect(await error).toEqual({ type: "error", error: "invalid-json" });
    peer.ws.close();
  });
});
