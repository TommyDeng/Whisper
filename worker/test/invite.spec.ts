// 验收测试：配对 InviteDO。协议见 docs/relay-protocol.md 第二节。
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { MAX_PAIR_PAYLOAD_CHARS } from "../src/relay_limits";
import { type Client, connect, randomId, request } from "./helpers";

type Role = "inviter" | "joiner";

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function path(id: string, role: Role, key: string, expires?: number): string {
  const suffix = expires === undefined ? "" : `&expires=${expires}`;
  return `/invite/${id}?role=${role}&key=${key}${suffix}`;
}

function stubOf(id: string) {
  return env.INVITES.get(env.INVITES.idFromName(id));
}

async function expectRejected(response: Response, status: number, error: string): Promise<void> {
  expect(response.status).toBe(status);
  await expect(response.json()).resolves.toEqual({ ok: false, error });
}

/** 登记一个邀请，返回已读完 welcome 的邀请人连接。 */
async function register(id: string, inviterKey: string): Promise<Client> {
  const inviter = await connect(path(id, "inviter", inviterKey, nowSeconds() + 3600));
  expect(await inviter.next()).toEqual({ type: "welcome", role: "inviter", state: "open" });
  return inviter;
}

/** 登记邀请并让加入者发出请求，状态到 requested。 */
async function requested(
  id: string,
  inviterKey: string,
  joinerKey: string,
): Promise<{ inviter: Client; joiner: Client }> {
  const inviter = await register(id, inviterKey);
  const joiner = await connect(path(id, "joiner", joinerKey));
  expect(await joiner.next()).toEqual({ type: "welcome", role: "joiner", state: "open" });
  joiner.send({ type: "pair-request", payload: "REQ" });
  expect(await joiner.next()).toEqual({ type: "stored" });
  expect(await inviter.next()).toEqual({ type: "pair-request", payload: "REQ" });
  return { inviter, joiner };
}

describe("invite route", () => {
  it("validates the invite id, role, key and upgrade header", async () => {
    const id = randomId();
    const key = randomId();
    await expectRejected(await request(`/invite/short?role=joiner&key=${key}`), 400, "bad-invite-id");
    await expectRejected(await request(`/invite/${id}?role=owner&key=${key}`), 400, "bad-role");
    await expectRejected(await request(`/invite/${id}?role=joiner`), 400, "bad-key");
    await expectRejected(await request(`/invite/${id}?role=joiner&key=short`), 400, "bad-key");
    expect((await request(path(id, "joiner", key), false)).status).toBe(426);
  });
});

describe("invite registration", () => {
  it("rejects a joiner for an invite nobody registered", async () => {
    await expectRejected(await request(path(randomId(), "joiner", randomId())), 404, "invite-not-found");
  });

  it("requires a sane expiry from the inviter", async () => {
    const key = randomId();
    await expectRejected(await request(path(randomId(), "inviter", key)), 400, "bad-expiry");
    await expectRejected(
      await request(`/invite/${randomId()}?role=inviter&key=${key}&expires=soon`),
      400,
      "bad-expiry",
    );
    await expectRejected(
      await request(path(randomId(), "inviter", key, nowSeconds() - 10)),
      400,
      "bad-expiry",
    );
    await expectRejected(
      await request(path(randomId(), "inviter", key, nowSeconds() + 24 * 3600 + 900)),
      400,
      "bad-expiry",
    );
    // 一次失败的登记不会留下记录
    const id = randomId();
    await expectRejected(await request(path(id, "inviter", key)), 400, "bad-expiry");
    await expectRejected(await request(path(id, "joiner", randomId())), 404, "invite-not-found");
  });

  it("accepts a 24 hour invite and schedules its expiry", async () => {
    const id = randomId();
    const expires = nowSeconds() + 24 * 3600;
    const inviter = await connect(path(id, "inviter", randomId(), expires));
    expect(await inviter.next()).toEqual({ type: "welcome", role: "inviter", state: "open" });
    const { record, alarm } = await runInDurableObject(stubOf(id), async (_instance, state) => ({
      record: await state.storage.get<Record<string, unknown>>("invite"),
      alarm: await state.storage.getAlarm(),
    }));
    expect(record).toMatchObject({ state: "open", expiresAt: expires * 1000 });
    expect(alarm).toBe(expires * 1000);
    inviter.close();
  });

  it("only lets the registering key come back as inviter", async () => {
    const id = randomId();
    const key = randomId();
    const inviter = await register(id, key);
    await expectRejected(await request(path(id, "inviter", randomId())), 403, "forbidden");

    // 同一 key 重连：不需要再带 expires，旧连接被替换
    const again = await connect(path(id, "inviter", key));
    expect(await again.next()).toEqual({ type: "welcome", role: "inviter", state: "open" });
    expect(await inviter.closed).toMatchObject({ code: 4001 });
    again.close();
  });
});

describe("pairing flow", () => {
  it("runs request, approval and completion, then refuses reuse", async () => {
    const id = randomId();
    const inviterKey = randomId();
    const joinerKey = randomId();
    const { inviter, joiner } = await requested(id, inviterKey, joinerKey);

    inviter.send({ type: "pair-response", accepted: true, payload: "RESP", extra: "dropped" });
    expect(await inviter.next()).toEqual({ type: "stored" });
    expect(await joiner.next()).toEqual({ type: "pair-response", accepted: true, payload: "RESP" });

    joiner.send({ type: "pair-done" });
    expect(await inviter.next()).toEqual({ type: "pair-done" });
    expect(await inviter.closed).toMatchObject({ code: 1000 });
    expect(await joiner.closed).toMatchObject({ code: 1000 });

    await expectRejected(await request(path(id, "joiner", joinerKey)), 410, "invite-used");
    await expectRejected(await request(path(id, "joiner", randomId())), 410, "invite-used");
    await expectRejected(await request(path(id, "inviter", inviterKey)), 410, "invite-used");
    await expectRejected(await request(path(id, "inviter", randomId())), 403, "forbidden");

    // 完成后不再保留请求和应答的内容
    const record = await runInDurableObject(stubOf(id), (_instance, state) =>
      state.storage.get<Record<string, unknown>>("invite"),
    );
    expect(record).toMatchObject({ state: "done" });
    expect(record?.request).toBeUndefined();
    expect(record?.response).toBeUndefined();
  });

  it("holds the request and the response while the other side is offline", async () => {
    const id = randomId();
    const inviterKey = randomId();
    const joinerKey = randomId();
    (await register(id, inviterKey)).close();

    const joiner = await connect(path(id, "joiner", joinerKey));
    expect(await joiner.next()).toEqual({ type: "welcome", role: "joiner", state: "open" });
    joiner.send({ type: "pair-request", payload: "REQ" });
    expect(await joiner.next()).toEqual({ type: "stored" });
    joiner.close();

    const inviter = await connect(path(id, "inviter", inviterKey));
    expect(await inviter.next()).toEqual({ type: "welcome", role: "inviter", state: "requested" });
    expect(await inviter.next()).toEqual({ type: "pair-request", payload: "REQ" });
    inviter.send({ type: "pair-response", accepted: false, payload: "" });
    expect(await inviter.next()).toEqual({ type: "stored" });
    inviter.close();

    const back = await connect(path(id, "joiner", joinerKey));
    expect(await back.next()).toEqual({ type: "welcome", role: "joiner", state: "responded" });
    expect(await back.next()).toEqual({ type: "pair-response", accepted: false, payload: "" });
    back.send({ type: "pair-done" });
    expect(await back.closed).toMatchObject({ code: 1000 });
    await expectRejected(await request(path(id, "joiner", joinerKey)), 410, "invite-used");
  });

  it("is single use: a second joiner is refused once a request exists", async () => {
    const id = randomId();
    const { inviter, joiner } = await requested(id, randomId(), randomId());
    await expectRejected(await request(path(id, "joiner", randomId())), 410, "invite-used");
    inviter.close();
    joiner.close();
  });

  it("closes a joiner that loses the race for the invite", async () => {
    const id = randomId();
    const inviter = await register(id, randomId());
    const winner = await connect(path(id, "joiner", randomId()));
    await winner.next();
    const loser = await connect(path(id, "joiner", randomId()));
    expect(await loser.next()).toEqual({ type: "welcome", role: "joiner", state: "open" });

    winner.send({ type: "pair-request", payload: "FIRST" });
    expect(await winner.next()).toEqual({ type: "stored" });
    loser.send({ type: "pair-request", payload: "SECOND" });
    expect(await loser.next()).toEqual({ type: "error", error: "invite-used" });
    expect(await loser.closed).toMatchObject({ code: 4003 });

    expect(await inviter.next()).toEqual({ type: "pair-request", payload: "FIRST" });
    await inviter.expectNothingPending();
    inviter.close();
    winner.close();
  });

  it("rejects frames from the wrong role or in the wrong state", async () => {
    const id = randomId();
    const inviter = await register(id, randomId());
    const joiner = await connect(path(id, "joiner", randomId()));
    await joiner.next();

    inviter.send({ type: "pair-request", payload: "x" });
    expect(await inviter.next()).toEqual({ type: "error", error: "not-allowed" });
    inviter.send({ type: "pair-done" });
    expect(await inviter.next()).toEqual({ type: "error", error: "not-allowed" });
    joiner.send({ type: "pair-response", accepted: true, payload: "x" });
    expect(await joiner.next()).toEqual({ type: "error", error: "not-allowed" });

    inviter.send({ type: "pair-response", accepted: true, payload: "x" });
    expect(await inviter.next()).toEqual({ type: "error", error: "bad-state" });
    joiner.send({ type: "pair-done" });
    expect(await joiner.next()).toEqual({ type: "error", error: "bad-state" });

    joiner.send({ type: "pair-request" });
    expect(await joiner.next()).toEqual({ type: "error", error: "bad-payload" });
    joiner.send({ type: "pair-request", payload: "" });
    expect(await joiner.next()).toEqual({ type: "error", error: "bad-payload" });
    joiner.send({ type: "pair-request", payload: "a".repeat(MAX_PAIR_PAYLOAD_CHARS + 1) });
    expect(await joiner.next()).toEqual({ type: "error", error: "too-large" });

    // 以上都没有改变状态
    joiner.send({ type: "pair-request", payload: "REQ" });
    expect(await joiner.next()).toEqual({ type: "stored" });
    expect(await inviter.next()).toEqual({ type: "pair-request", payload: "REQ" });

    joiner.send({ type: "pair-request", payload: "AGAIN" });
    expect(await joiner.next()).toEqual({ type: "error", error: "bad-state" });
    inviter.send({ type: "pair-response", accepted: "yes", payload: "x" });
    expect(await inviter.next()).toEqual({ type: "error", error: "bad-accepted" });
    inviter.send({ type: "pair-response", accepted: true });
    expect(await inviter.next()).toEqual({ type: "error", error: "bad-payload" });
    inviter.send({ type: "pair-response", accepted: true, payload: "a".repeat(MAX_PAIR_PAYLOAD_CHARS + 1) });
    expect(await inviter.next()).toEqual({ type: "error", error: "too-large" });

    inviter.send({ type: "pair-response", accepted: true, payload: "RESP" });
    expect(await inviter.next()).toEqual({ type: "stored" });
    expect(await joiner.next()).toEqual({ type: "pair-response", accepted: true, payload: "RESP" });
    inviter.send({ type: "pair-response", accepted: false, payload: "" });
    expect(await inviter.next()).toEqual({ type: "error", error: "bad-state" });
    inviter.close();
    joiner.close();
  });

  it("answers pings and reports malformed frames", async () => {
    const inviter = await register(randomId(), randomId());
    inviter.send({ type: "ping" });
    expect(await inviter.next()).toEqual({ type: "pong" });
    inviter.send("{");
    expect(await inviter.next()).toEqual({ type: "error", error: "invalid-json" });
    inviter.send("[]");
    expect(await inviter.next()).toEqual({ type: "error", error: "expected-object" });
    inviter.send({ type: "nope" });
    expect(await inviter.next()).toEqual({ type: "error", error: "unknown-type" });
    inviter.close();
  });
});

describe("invite expiry", () => {
  it("refuses a joiner after the invite expired and forgets the invite", async () => {
    const id = randomId();
    (await register(id, randomId())).close();
    await runInDurableObject(stubOf(id), async (_instance, state) => {
      const record = await state.storage.get<Record<string, unknown>>("invite");
      await state.storage.put("invite", { ...record, expiresAt: Date.now() - 1 });
    });
    await expectRejected(await request(path(id, "joiner", randomId())), 410, "invite-expired");
    await expectRejected(await request(path(id, "joiner", randomId())), 404, "invite-not-found");
  });

  it("closes connections and deletes everything when the alarm fires", async () => {
    const id = randomId();
    const { inviter, joiner } = await requested(id, randomId(), randomId());
    const stub = stubOf(id);
    await runInDurableObject(stub, async (_instance, state) => {
      const record = await state.storage.get<Record<string, unknown>>("invite");
      await state.storage.put("invite", { ...record, expiresAt: Date.now() - 1 });
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    expect(await inviter.closed).toMatchObject({ code: 4002 });
    expect(await joiner.closed).toMatchObject({ code: 4002 });
    const size = await runInDurableObject(stub, async (_instance, state) =>
      (await state.storage.list()).size,
    );
    expect(size).toBe(0);
    await expectRejected(await request(path(id, "joiner", randomId())), 404, "invite-not-found");
  });
});
