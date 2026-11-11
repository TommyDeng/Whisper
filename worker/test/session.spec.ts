// 验收测试：会话中继 SessionDO。协议见 docs/relay-protocol.md 第一节。
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  MAX_PAYLOAD_CHARS,
  OFFLINE_TTL_MS,
  RATE_LIMIT_MAX_FRAMES,
  isExpired,
} from "../src/relay_limits";
import { type Client, connect, randomId, request } from "./helpers";

function session(id: string, peer: "a" | "b"): Promise<Client> {
  return connect(`/session/${id}?peer=${peer}`);
}

function stubOf(id: string) {
  return env.SESSIONS.get(env.SESSIONS.idFromName(id));
}

describe("relay limits", () => {
  it("keeps offline messages for exactly seven days", () => {
    expect(OFFLINE_TTL_MS).toBe(604_800_000);
    expect(isExpired(1000, 1000 + OFFLINE_TTL_MS - 1)).toBe(false);
    expect(isExpired(1000, 1000 + OFFLINE_TTL_MS)).toBe(true);
  });
});

describe("session route", () => {
  it("validates the session id, the peer and the upgrade header", async () => {
    const short = await request("/session/short?peer=a");
    expect(short.status).toBe(400);
    await expect(short.json()).resolves.toEqual({ ok: false, error: "bad-session-id" });

    const id = randomId();
    const noPeer = await request(`/session/${id}`);
    expect(noPeer.status).toBe(400);
    await expect(noPeer.json()).resolves.toEqual({ ok: false, error: "bad-peer" });
    expect((await request(`/session/${id}?peer=c`)).status).toBe(400);

    expect((await request(`/session/${id}?peer=a`, false)).status).toBe(426);
  });
});

describe("session relay", () => {
  it("welcomes both peers and reports presence", async () => {
    const id = randomId();
    const a = await session(id, "a");
    expect(await a.next()).toEqual({ type: "welcome", peer: "a", peerOnline: false });

    const b = await session(id, "b");
    expect(await b.next()).toEqual({ type: "welcome", peer: "b", peerOnline: true });
    expect(await a.next()).toEqual({ type: "peer-online" });

    b.close();
    expect(await a.next()).toEqual({ type: "peer-offline" });
    a.close();
  });

  it("forwards a message to an online peer, and reports delivery on ack", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();
    const b = await session(id, "b");
    await b.next();

    const before = Date.now();
    a.send({ type: "msg", id: "m1", payload: "Y2lwaGVy", extra: "not forwarded" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "m1" });
    const received = await b.nextData();
    expect(received).toEqual({ type: "msg", id: "m1", payload: "Y2lwaGVy", ts: expect.any(Number) });
    expect(received.ts as number).toBeGreaterThanOrEqual(before - 1000);
    expect(received.ts as number).toBeLessThanOrEqual(Date.now() + 1000);

    b.send({ type: "ack", id: "m1" });
    expect(await a.nextData()).toEqual({ type: "delivered", id: "m1" });

    // 已确认的消息不会在重连时再投递
    b.close();
    const again = await session(id, "b");
    expect(await again.next()).toMatchObject({ type: "welcome", peer: "b" });
    await again.expectNothingPending();
    a.close();
    again.close();
  });

  it("queues messages for an offline peer in order and redelivers until acked", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();
    for (const mid of ["m1", "m2", "m3"]) {
      a.send({ type: "msg", id: mid, payload: `p-${mid}` });
      expect(await a.nextData()).toEqual({ type: "stored", id: mid });
    }

    const first = await session(id, "b");
    expect(await first.next()).toEqual({ type: "welcome", peer: "b", peerOnline: true });
    for (const mid of ["m1", "m2", "m3"]) {
      expect(await first.next()).toMatchObject({ type: "msg", id: mid, payload: `p-${mid}` });
    }
    first.close();

    // 没有 ack：重连后全部重新投递
    const second = await session(id, "b");
    await second.next();
    for (const mid of ["m1", "m2", "m3"]) {
      expect(await second.next()).toMatchObject({ type: "msg", id: mid });
    }
    second.send({ type: "ack", id: "m2" });
    await second.expectNothingPending();
    second.close();

    const third = await session(id, "b");
    await third.next();
    expect(await third.next()).toMatchObject({ type: "msg", id: "m1" });
    expect(await third.next()).toMatchObject({ type: "msg", id: "m3" });
    await third.expectNothingPending();
    a.close();
    third.close();
  });

  it("queues independently in each direction", async () => {
    const id = randomId();
    const b = await session(id, "b");
    await b.next();
    b.send({ type: "msg", id: "from-b", payload: "to-a" });
    expect(await b.nextData()).toEqual({ type: "stored", id: "from-b" });
    b.close();

    const a = await session(id, "a");
    expect(await a.next()).toMatchObject({ type: "welcome", peer: "a" });
    expect(await a.nextData()).toMatchObject({ type: "msg", id: "from-b", payload: "to-a" });
    a.send({ type: "msg", id: "from-a", payload: "to-b" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "from-a" });
    a.close();

    const again = await session(id, "b");
    await again.next();
    expect(await again.nextData()).toMatchObject({ type: "msg", id: "from-a", payload: "to-b" });
    await again.expectNothingPending();
    again.close();
  });

  it("does not let the sender ack away its own message", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();
    a.send({ type: "msg", id: "m1", payload: "x" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "m1" });
    a.send({ type: "ack", id: "m1" });
    a.send({ type: "ack", id: "no-such-id" });
    await a.expectNothingPending();

    const b = await session(id, "b");
    await b.next();
    expect(await b.next()).toMatchObject({ type: "msg", id: "m1" });
    a.close();
    b.close();
  });

  it("does not enqueue a resent id twice", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();
    a.send({ type: "msg", id: "dup", payload: "x" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "dup" });
    a.send({ type: "msg", id: "dup", payload: "x" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "dup" });

    const b = await session(id, "b");
    await b.next();
    expect(await b.next()).toMatchObject({ type: "msg", id: "dup" });
    await b.expectNothingPending();
    a.close();
    b.close();
  });

  it("forwards ephemeral messages without storing them", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();

    a.send({ type: "msg", id: "e1", payload: "offer", ephemeral: true });
    expect(await a.nextData()).toEqual({ type: "dropped", id: "e1" });

    const b = await session(id, "b");
    await b.next();
    await b.expectNothingPending();

    a.send({ type: "msg", id: "e2", payload: "offer", ephemeral: true });
    expect(await b.nextData()).toEqual({
      type: "msg",
      id: "e2",
      payload: "offer",
      ts: expect.any(Number),
    });
    await a.expectNothingPending();

    b.close();
    const again = await session(id, "b");
    await again.next();
    await again.expectNothingPending();
    a.close();
    again.close();
  });

  it("rejects malformed frames without closing the connection", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();

    a.send("{");
    expect(await a.next()).toEqual({ type: "error", error: "invalid-json" });
    a.send("[]");
    expect(await a.next()).toEqual({ type: "error", error: "expected-object" });
    a.send({ type: "nope" });
    expect(await a.next()).toEqual({ type: "error", error: "unknown-type" });

    a.send({ type: "msg", id: "has space", payload: "x" });
    expect(await a.next()).toEqual({ type: "error", error: "bad-id", id: "has space" });
    a.send({ type: "msg", id: 7, payload: "x" });
    expect(await a.next()).toEqual({ type: "error", error: "bad-id" });
    a.send({ type: "msg", id: "m1" });
    expect(await a.next()).toEqual({ type: "error", error: "bad-payload", id: "m1" });
    a.send({ type: "msg", id: "m1", payload: "" });
    expect(await a.next()).toEqual({ type: "error", error: "bad-payload", id: "m1" });
    a.send({ type: "msg", id: "m1", payload: "a".repeat(MAX_PAYLOAD_CHARS + 1) });
    expect(await a.next()).toEqual({ type: "error", error: "too-large", id: "m1" });
    a.send({ type: "ack", id: 7 });
    expect(await a.next()).toEqual({ type: "error", error: "bad-id" });

    // 最大长度的 payload 可以通过
    a.send({ type: "msg", id: "big", payload: "a".repeat(MAX_PAYLOAD_CHARS) });
    expect(await a.next()).toEqual({ type: "stored", id: "big" });

    // 上面被拒绝的帧都没有入队
    const b = await session(id, "b");
    await b.next();
    expect(await b.next()).toMatchObject({ type: "msg", id: "big" });
    await b.expectNothingPending();
    a.close();
    b.close();
  });

  it("replaces an older connection of the same peer without announcing it offline", async () => {
    const id = randomId();
    const b = await session(id, "b");
    await b.next();
    const first = await session(id, "a");
    await first.next();
    expect(await b.next()).toEqual({ type: "peer-online" });

    const second = await session(id, "a");
    expect(await second.next()).toEqual({ type: "welcome", peer: "a", peerOnline: true });
    expect(await first.closed).toMatchObject({ code: 4001 });

    const seen = await b.drain(300);
    expect(seen.filter((frame) => frame.type === "peer-offline")).toEqual([]);

    // 新连接正常工作
    second.send({ type: "msg", id: "m1", payload: "x" });
    expect(await b.nextData()).toMatchObject({ type: "msg", id: "m1" });
    second.close();
    b.close();
  });

  it("rate-limits frames per connection", async () => {
    const id = randomId();
    const a = await session(id, "a");
    await a.next();
    const total = RATE_LIMIT_MAX_FRAMES + 10;
    for (let i = 0; i < total; i += 1) a.send({ type: "ping" });
    let pongs = 0;
    let limited = 0;
    for (let i = 0; i < total; i += 1) {
      const frame = await a.next();
      if (frame.type === "pong") pongs += 1;
      else if (frame.type === "error" && frame.error === "rate-limited") limited += 1;
    }
    expect(pongs).toBe(RATE_LIMIT_MAX_FRAMES);
    expect(limited).toBe(10);
    a.close();
  });

  it("counts malformed frames toward the rate limit", async () => {
    const a = await session(randomId(), "a");
    await a.next();
    for (let i = 0; i < RATE_LIMIT_MAX_FRAMES; i += 1) a.send(i % 2 === 0 ? "{" : { type: "nope" });
    a.send({ type: "ping" });
    for (let i = 0; i < RATE_LIMIT_MAX_FRAMES; i += 1) {
      expect(await a.next()).toMatchObject({ type: "error", error: i % 2 === 0 ? "invalid-json" : "unknown-type" });
    }
    expect(await a.next()).toEqual({ type: "error", error: "rate-limited" });
    a.close();
  });

  it("drops expired messages when a peer connects", async () => {
    const id = randomId();
    const stub = stubOf(id);
    const expiredKey = "q:b:000000000000";
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put(expiredKey, {
        id: "old",
        payload: "x",
        ts: Date.now() - OFFLINE_TTL_MS - 1000,
      });
    });

    const a = await session(id, "a");
    await a.next();
    a.send({ type: "msg", id: "fresh", payload: "y" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "fresh" });

    const b = await session(id, "b");
    await b.next();
    expect(await b.next()).toMatchObject({ type: "msg", id: "fresh" });
    await b.expectNothingPending();

    const leftover = await runInDurableObject(stub, (_instance, state) =>
      state.storage.get(expiredKey),
    );
    expect(leftover).toBeUndefined();
    a.close();
    b.close();
  });

  it("stores queue entries in the documented layout and purges them from an alarm", async () => {
    const id = randomId();
    const stub = stubOf(id);
    const a = await session(id, "a");
    await a.next();
    const before = Date.now();
    a.send({ type: "msg", id: "m1", payload: "x" });
    expect(await a.nextData()).toEqual({ type: "stored", id: "m1" });
    a.close();

    const { entries, alarm } = await runInDurableObject(stub, async (_instance, state) => ({
      entries: [...(await state.storage.list<{ id: string; payload: string; ts: number }>({ prefix: "q:b:" }))],
      alarm: await state.storage.getAlarm(),
    }));
    expect(entries).toHaveLength(1);
    expect(entries[0][0]).toMatch(/^q:b:\d{12}$/);
    expect(entries[0][1]).toEqual({ id: "m1", payload: "x", ts: expect.any(Number) });
    expect(alarm).not.toBeNull();
    expect(alarm as number).toBeGreaterThan(before);
    expect(alarm as number).toBeLessThanOrEqual(Date.now() + OFFLINE_TTL_MS + 1000);

    // 把这条消息改成已过期，然后立即触发 alarm
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put(entries[0][0], {
        ...entries[0][1],
        ts: Date.now() - OFFLINE_TTL_MS - 1000,
      });
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    const remaining = await runInDurableObject(stub, async (_instance, state) =>
      (await state.storage.list({ prefix: "q:b:" })).size,
    );
    expect(remaining).toBe(0);
  });
});
