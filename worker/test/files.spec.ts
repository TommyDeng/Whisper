// 文件中转接口：密文分块暂存在 R2。约定见 docs/file-relay.md。
import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { handleFileRequest } from "../src/files";
import {
  FILE_RATE_LIMIT_MAX_REQUESTS,
  FILE_SESSION_QUOTA_BYTES,
  MAX_FILE_CHUNK_BYTES,
  OFFLINE_TTL_MS,
} from "../src/relay_limits";

/** 43 个 URL 安全字符（32 字节随机数的 base64url，无填充）。 */
function randomFileId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}

/** 22 个 URL 安全字符，满足 RELAY_ID。 */
function randomSessionId(): string {
  return randomFileId().slice(0, 22);
}

function authHeaders(sessionId: string, peer: "a" | "b" = "a"): Record<string, string> {
  return { authorization: `Whisper ${sessionId} ${peer}` };
}

function call(
  method: string,
  path: string,
  body?: BodyInit,
  sessionId?: string,
  peer: "a" | "b" = "a",
): Promise<Response> {
  const headers = sessionId ? authHeaders(sessionId, peer) : {};
  return exports.default.fetch(`http://example.com${path}`, { method, body, headers });
}

/** 绕过路由直接调用处理函数，用来注入“现在”的时间。 */
async function callAt(
  nowMs: number,
  method: string,
  path: string,
  body?: BodyInit,
  sessionId?: string,
): Promise<Response> {
  const headers = sessionId ? authHeaders(sessionId) : {};
  const request = new Request(`http://example.com${path}`, { method, body, headers });
  const response = await handleFileRequest(request, env, new URL(request.url), nowMs);
  if (!response) throw new Error("not a /file/ path");
  return response;
}

async function expectError(response: Response, status: number, error: string): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(await response.json()).toEqual({ ok: false, error });
}

async function expectOk(response: Response, status: number): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(await response.json()).toEqual({ ok: true });
}

async function stored(key: string): Promise<Uint8Array | null> {
  const object = await env.FILES.get(key);
  return object ? new Uint8Array(await object.arrayBuffer()) : null;
}

const bytes = (...values: number[]): Uint8Array => new Uint8Array(values);

describe("PUT / GET /file/<fileId>/<index>", () => {
  it("上传后能原样下载", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(0, 1, 2, 255), session), 201);
    expect(await stored(`${id}/0`)).toEqual(bytes(0, 1, 2, 255));

    const response = await call("GET", `/file/${id}/0`, undefined, session);
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/octet-stream");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes(0, 1, 2, 255));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("同一会话的另一个 peer 也能下载和删除", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(9), session, "a"), 201);
    const response = await call("GET", `/file/${id}/0`, undefined, session, "b");
    expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes(9));
    await expectOk(await call("DELETE", `/file/${id}`, undefined, session, "b"), 200);
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("各块互不影响，序号上限 127 可用", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    await expectOk(await call("PUT", `/file/${id}/127`, bytes(2), session), 201);
    expect(new Uint8Array(await (await call("GET", `/file/${id}/0`, undefined, session)).arrayBuffer())).toEqual(
      bytes(1),
    );
    expect(new Uint8Array(await (await call("GET", `/file/${id}/127`, undefined, session)).arrayBuffer())).toEqual(
      bytes(2),
    );
    await env.FILES.delete([`${id}/0`, `${id}/127`, `${id}/owner`]);
  });

  it("下载不存在的块：404 not-found", async () => {
    await expectError(await call("GET", `/file/${randomFileId()}/0`, undefined, randomSessionId()), 404, "not-found");
  });

  it("正好达到上限的块可以上传", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const chunk = new Uint8Array(MAX_FILE_CHUNK_BYTES).fill(7);
    await expectOk(await call("PUT", `/file/${id}/3`, chunk, session), 201);
    expect((await env.FILES.head(`${id}/3`))?.size).toBe(MAX_FILE_CHUNK_BYTES);
    await env.FILES.delete([`${id}/3`, `${id}/owner`]);
  });

  it("超过上限：413 chunk-too-large，不写入存储", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const chunk = new Uint8Array(MAX_FILE_CHUNK_BYTES + 1);
    await expectError(await call("PUT", `/file/${id}/0`, chunk, session), 413, "chunk-too-large");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("没有 content-length 的流式超限请求体同样被拒绝，不写入存储", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const half = new Uint8Array(MAX_FILE_CHUNK_BYTES / 2 + 8);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(half);
        controller.enqueue(half);
        controller.enqueue(bytes(1));
        controller.close();
      },
    });
    const request = new Request(`http://example.com/file/${id}/0`, {
      method: "PUT",
      body: stream,
      duplex: "half",
      headers: authHeaders(session),
    } as RequestInit);
    expect(request.headers.get("content-length")).toBeNull();
    const response = await handleFileRequest(request, env, new URL(request.url));
    await expectError(response!, 413, "chunk-too-large");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
  });

  it("空请求体：400 empty-chunk，不写入存储", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectError(await call("PUT", `/file/${id}/0`, undefined, session), 400, "empty-chunk");
    await expectError(await call("PUT", `/file/${id}/0`, new Uint8Array(0), session), 400, "empty-chunk");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("同一块再次上传：409 chunk-exists，不覆盖原内容", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/5`, bytes(1, 2, 3), session), 201);
    await expectError(await call("PUT", `/file/${id}/5`, bytes(9, 9), session), 409, "chunk-exists");
    expect(await stored(`${id}/5`)).toEqual(bytes(1, 2, 3));
    await env.FILES.delete([`${id}/5`, `${id}/owner`]);
  });
});

describe("DELETE /file/<fileId>", () => {
  it("删除这个文件的全部块，不动别的文件", async () => {
    const id = randomFileId();
    const other = randomFileId();
    const session = randomSessionId();
    const otherSession = randomSessionId();
    for (const index of [0, 1, 10]) {
      await expectOk(await call("PUT", `/file/${id}/${index}`, bytes(index + 1), session), 201);
    }
    await expectOk(await call("PUT", `/file/${other}/0`, bytes(42), otherSession), 201);

    await expectOk(await call("DELETE", `/file/${id}`, undefined, session), 200);
    expect((await env.FILES.list({ prefix: `${id}/` })).objects).toEqual([]);
    await expectError(await call("GET", `/file/${id}/1`, undefined, session), 404, "not-found");
    expect(await stored(`${other}/0`)).toEqual(bytes(42));
    await env.FILES.delete([`${other}/0`, `${other}/owner`]);
  });

  it("没有块也算成功", async () => {
    await expectOk(await call("DELETE", `/file/${randomFileId()}`, undefined, randomSessionId()), 200);
  });
});

describe("过期", () => {
  it("上传不满 7 天的块仍可下载", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const uploadedAt = Date.now();
    await expectOk(await callAt(uploadedAt, "PUT", `/file/${id}/0`, bytes(1), session), 201);
    const stillThere = (await env.FILES.head(`${id}/0`))!.uploaded.getTime() + OFFLINE_TTL_MS - 1;
    const response = await callAt(stillThere, "GET", `/file/${id}/0`, undefined, session);
    expect(response.status).toBe(200);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(bytes(1));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("上传满 7 天的块：GET 返回 404 not-found 并删除", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    const expiredAt = (await env.FILES.head(`${id}/0`))!.uploaded.getTime() + OFFLINE_TTL_MS;
    await expectError(await callAt(expiredAt, "GET", `/file/${id}/0`, undefined, session), 404, "not-found");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("已过期的块按不存在处理：可以重新上传", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    const expiredAt = (await env.FILES.head(`${id}/0`))!.uploaded.getTime() + OFFLINE_TTL_MS;
    await expectOk(await callAt(expiredAt, "PUT", `/file/${id}/0`, bytes(2, 2), session), 201);
    expect(await stored(`${id}/0`)).toEqual(bytes(2, 2));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });
});

describe("入口校验", () => {
  const badIds = [
    "short",
    "a".repeat(42),
    "a".repeat(44),
    `${"a".repeat(42)}.`,
    `${"a".repeat(42)}%2B`,
  ];

  it("fileId 不合格：三个方法都是 400 bad-file-id", async () => {
    for (const id of badIds) {
      await expectError(await call("PUT", `/file/${id}/0`, bytes(1)), 400, "bad-file-id");
      await expectError(await call("GET", `/file/${id}/0`), 400, "bad-file-id");
      await expectError(await call("DELETE", `/file/${id}`), 400, "bad-file-id");
    }
  });

  it("index 不合格：400 bad-chunk-index", async () => {
    const id = randomFileId();
    for (const index of ["x", "-1", "1a", "01", "00", "128", "1000", "1.0", "+1", "１"]) {
      const path = `/file/${id}/${encodeURIComponent(index)}`;
      await expectError(await call("PUT", path, bytes(1)), 400, "bad-chunk-index");
      await expectError(await call("GET", path), 400, "bad-chunk-index");
    }
    expect((await env.FILES.list({ prefix: `${id}/` })).objects).toEqual([]);
  });

  it("fileId 和 index 都不合格时先报 bad-file-id", async () => {
    await expectError(await call("GET", "/file/short/999"), 400, "bad-file-id");
  });

  it("其它方法：405 method-not-allowed", async () => {
    const id = randomFileId();
    for (const method of ["POST", "PATCH", "HEAD"]) {
      const chunk = await call(method, `/file/${id}/0`);
      expect(chunk.status).toBe(405);
      expect(chunk.headers.get("cache-control")).toBe("no-store");
      const file = await call(method, `/file/${id}`);
      expect(file.status).toBe(405);
    }
    await expectError(await call("POST", `/file/${id}/0`, bytes(1)), 405, "method-not-allowed");
    await expectError(await call("POST", `/file/${id}`), 405, "method-not-allowed");
  });

  it("方法和路径不匹配：405 method-not-allowed，不改动存储", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    await expectError(await call("DELETE", `/file/${id}/0`, undefined, session), 405, "method-not-allowed");
    await expectError(await call("GET", `/file/${id}`, undefined, session), 405, "method-not-allowed");
    await expectError(await call("PUT", `/file/${id}`, bytes(1), session), 405, "method-not-allowed");
    expect(await stored(`${id}/0`)).toEqual(bytes(1));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("不是 /file/<fileId>[/<index>] 形状的路径不归文件接口处理", async () => {
    const id = randomFileId();
    for (const path of ["/file", "/file/", `/file/${id}/0/extra`, `/files/${id}/0`]) {
      const response = await call("GET", path);
      expect(response.status).toBe(404);
      await response.arrayBuffer();
    }
  });
});

describe("鉴权", () => {
  it("缺少或格式不对的凭据：401 unauthorized，不写入", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await expectError(await call("PUT", `/file/${id}/0`, bytes(1)), 401, "unauthorized");
    await expectError(await call("GET", `/file/${id}/0`), 401, "unauthorized");
    await expectError(await call("DELETE", `/file/${id}`), 401, "unauthorized");

    const bad = [
      { authorization: "Bearer " + session + " a" },
      { authorization: `whisper ${session} a` },
      { authorization: `Whisper ${session}` },
      { authorization: `Whisper ${session} c` },
      { authorization: `Whisper short a` },
    ];
    for (const headers of bad) {
      const response = await exports.default.fetch(`http://example.com/file/${id}/0`, {
        method: "PUT",
        body: bytes(1),
        headers,
      });
      await expectError(response, 401, "unauthorized");
    }
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("其它会话：403 forbidden，不能读写删，也不能靠 409 探查", async () => {
    const id = randomFileId();
    const owner = randomSessionId();
    const other = randomSessionId();
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1, 2, 3), owner), 201);

    await expectError(await call("PUT", `/file/${id}/0`, bytes(9), other), 403, "forbidden");
    await expectError(await call("PUT", `/file/${id}/1`, bytes(9), other), 403, "forbidden");
    await expectError(await call("GET", `/file/${id}/0`, undefined, other), 403, "forbidden");
    await expectError(await call("DELETE", `/file/${id}`, undefined, other), 403, "forbidden");
    expect(await stored(`${id}/0`)).toEqual(bytes(1, 2, 3));

    await expectOk(await call("DELETE", `/file/${randomFileId()}`, undefined, other), 200);
    expect(await stored(`${id}/0`)).toEqual(bytes(1, 2, 3));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("内部记账接口不能从公网走到", async () => {
    const session = randomSessionId();
    const asPublic = await exports.default.fetch(`http://example.com/session/${session}/file-auth`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ fileId: randomFileId(), op: "put", bytes: 1, nowMs: Date.now() }),
    });
    expect(asPublic.status).toBe(404);
    await asPublic.arrayBuffer();

    const noUpgrade = await exports.default.fetch(`http://example.com/session/${session}`, { method: "POST" });
    expect(noUpgrade.status).toBe(400);
    await noUpgrade.arrayBuffer();
  });
});

describe("配额与限速", () => {
  async function seedUsage(
    sessionId: string,
    usage: { bytes?: number; count?: number; windowStart?: number; updatedAt?: number },
  ): Promise<void> {
    const stub = env.SESSIONS.get(env.SESSIONS.idFromName(sessionId));
    const now = usage.updatedAt ?? usage.windowStart ?? Date.now();
    await runInDurableObject(stub, async (_instance, state) => {
      await state.storage.put("file-usage", {
        files: { [randomFileId()]: { bytes: usage.bytes ?? 0, updatedAt: now } },
        windowStart: usage.windowStart ?? now,
        count: usage.count ?? 0,
      });
    });
  }

  it("超过会话总量：413 quota-exceeded，不写入", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await seedUsage(session, { bytes: FILE_SESSION_QUOTA_BYTES - 5, windowStart: Date.now() - 60_000 });
    await expectError(await call("PUT", `/file/${id}/0`, bytes(1, 2, 3, 4, 5, 6), session), 413, "quota-exceeded");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
    expect(await env.FILES.head(`${id}/owner`)).toBeNull();
  });

  it("总量还差一点时，刚好放下的块可以上传", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await seedUsage(session, { bytes: FILE_SESSION_QUOTA_BYTES - 4, windowStart: Date.now() - 60_000 });
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1, 2, 3, 4), session), 201);
    expect(await stored(`${id}/0`)).toEqual(bytes(1, 2, 3, 4));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("超过请求速率：429 rate-limited，不写入", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const now = Date.now();
    await seedUsage(session, { bytes: 0, count: FILE_RATE_LIMIT_MAX_REQUESTS, windowStart: now });
    await expectError(await call("PUT", `/file/${id}/0`, bytes(1), session), 429, "rate-limited");
    expect(await env.FILES.head(`${id}/0`)).toBeNull();
  });

  it("窗口过后再上传不再被限速", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    await seedUsage(session, {
      bytes: 0,
      count: FILE_RATE_LIMIT_MAX_REQUESTS,
      windowStart: Date.now() - 10_000,
    });
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });

  it("占用满 7 天后释放，可以再上传", async () => {
    const id = randomFileId();
    const session = randomSessionId();
    const uploadedAt = Date.now() - OFFLINE_TTL_MS;
    await seedUsage(session, {
      bytes: FILE_SESSION_QUOTA_BYTES,
      updatedAt: uploadedAt,
      windowStart: uploadedAt,
      count: 0,
    });
    await expectOk(await call("PUT", `/file/${id}/0`, bytes(1), session), 201);
    expect(await stored(`${id}/0`)).toEqual(bytes(1));
    await env.FILES.delete([`${id}/0`, `${id}/owner`]);
  });
});
