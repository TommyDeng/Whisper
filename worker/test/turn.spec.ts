// TURN 临时凭据：向 Cloudflare Realtime 换短期凭据，长期密钥不下发。
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { TURN_TTL_SECONDS, cleanIceServers, issueTurnCredentials } from "../src/turn";
import { request } from "./helpers";

const upstreamBody = {
  iceServers: [
    { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
    {
      urls: [
        "turn:turn.cloudflare.com:3478?transport=udp",
        "turn:turn.cloudflare.com:53?transport=udp",
        "turns:turn.cloudflare.com:443?transport=tcp",
      ],
      username: "user",
      credential: "pass",
      extra: "不转发",
    },
  ],
};

describe("issueTurnCredentials", () => {
  it("没配置密钥：501，不请求上游", async () => {
    let called = false;
    const result = await issueTurnCredentials({}, async () => {
      called = true;
      return Response.json(upstreamBody, { status: 201 });
    });
    expect(result).toEqual({ ok: false, status: 501, error: "turn-not-configured" });
    expect(called).toBe(false);
  });

  it("用密钥向上游换凭据，只转发认识的字段，去掉 53 端口", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const result = await issueTurnCredentials(
      { TURN_KEY_ID: "key-id", TURN_KEY_API_TOKEN: "secret-token" },
      async (url, init) => {
        calls.push({ url, init });
        return Response.json(upstreamBody, { status: 201 });
      },
    );

    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(
      "https://rtc.live.cloudflare.com/v1/turn/keys/key-id/credentials/generate-ice-servers",
    );
    expect(calls[0].init.method).toBe("POST");
    expect((calls[0].init.headers as Record<string, string>).authorization).toBe("Bearer secret-token");
    expect(JSON.parse(calls[0].init.body as string)).toEqual({ ttl: TURN_TTL_SECONDS });

    expect(result).toEqual({
      ok: true,
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        {
          urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"],
          username: "user",
          credential: "pass",
        },
      ],
    });
    expect(JSON.stringify(result)).not.toContain("secret-token");
  });

  it("上游报错、连不上、返回内容不对：502", async () => {
    const env = { TURN_KEY_ID: "key-id", TURN_KEY_API_TOKEN: "secret-token" };
    expect(await issueTurnCredentials(env, async () => new Response("no", { status: 401 }))).toEqual({
      ok: false,
      status: 502,
      error: "turn-upstream-error",
    });
    expect(
      await issueTurnCredentials(env, async () => {
        throw new Error("network");
      }),
    ).toEqual({ ok: false, status: 502, error: "turn-upstream-unreachable" });
    expect(await issueTurnCredentials(env, async () => new Response("not json", { status: 201 }))).toEqual({
      ok: false,
      status: 502,
      error: "turn-upstream-error",
    });
    // 只有 STUN、没有带凭据的 TURN：当作失败
    expect(
      await issueTurnCredentials(env, async () =>
        Response.json({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }] }, { status: 201 }),
      ),
    ).toEqual({ ok: false, status: 502, error: "turn-upstream-error" });
  });
});

describe("cleanIceServers", () => {
  it("丢掉不认识的协议和格式不对的条目", () => {
    expect(
      cleanIceServers({
        iceServers: [
          { urls: ["https://example.com", "turn:a.example:3478"], username: "u", credential: "c" },
          { urls: 42 },
          "nope",
          { urls: "stun:b.example:3478" },
        ],
      }),
    ).toEqual([
      { urls: ["turn:a.example:3478"], username: "u", credential: "c" },
      { urls: ["stun:b.example:3478"] },
    ]);
    expect(cleanIceServers(null)).toEqual([]);
    expect(cleanIceServers({ iceServers: "x" })).toEqual([]);
  });

  it("上游返回单个对象时也接受", () => {
    expect(
      cleanIceServers({ iceServers: { urls: ["turn:a.example:3478"], username: "u", credential: "c" } }),
    ).toEqual([{ urls: ["turn:a.example:3478"], username: "u", credential: "c" }]);
  });
});

describe("GET /turn-credentials", () => {
  // 本地 .dev.vars 里配了真密钥时跳过，免得测试去请求真实服务
  const configured = Boolean((env as unknown as { TURN_KEY_ID?: string }).TURN_KEY_ID);
  it.skipIf(configured)("没配置密钥：501，不缓存", async () => {
    const response = await request("/turn-credentials", false);
    expect(response.status).toBe(501);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({ ok: false, error: "turn-not-configured" });
  });
});
