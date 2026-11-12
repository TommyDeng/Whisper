// 文件中转：密文分块暂存在 R2（绑定 FILES，对象名 `<fileId>/<index>`）。约定见 docs/file-relay.md。
// 隐私：这里不记录任何请求信息（路径、fileId、大小、IP、凭据）。
import { FILE_ID, MAX_CHUNK_INDEX, MAX_FILE_CHUNK_BYTES, RELAY_ID, isExpired } from "./relay_limits";
import { authorizeSessionFile } from "./session";

const NO_STORE = { "cache-control": "no-store" };

function ok(status = 200): Response {
  return Response.json({ ok: true }, { status, headers: NO_STORE });
}

function fail(error: string, status = 400): Response {
  return Response.json({ ok: false, error }, { status, headers: NO_STORE });
}

/** 十进制块序号，0–127，不带前导零；不合格返回 null。 */
function parseChunkIndex(text: string): number | null {
  if (!/^(0|[1-9][0-9]{0,2})$/.test(text)) return null;
  const index = Number(text);
  return index <= MAX_CHUNK_INDEX ? index : null;
}

/** Authorization: Whisper <sessionId> <peer>；不合格返回 null。 */
function parseFileAuth(request: Request): { sessionId: string; peer: "a" | "b" } | null {
  const header = request.headers.get("authorization");
  if (!header) return null;
  const match = /^Whisper ([A-Za-z0-9_-]{22,64}) ([ab])$/.exec(header);
  if (!match || !RELAY_ID.test(match[1])) return null;
  return { sessionId: match[1], peer: match[2] as "a" | "b" };
}

function ownerKey(fileId: string): string {
  return `${fileId}/owner`;
}

/** 读出请求体；超过 maxBytes 就停止读取并返回 null。 */
async function readBody(request: Request, maxBytes: number): Promise<Uint8Array | null> {
  if (Number(request.headers.get("content-length") ?? "0") > maxBytes) return null;
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    parts.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    body.set(part, offset);
    offset += part.byteLength;
  }
  return body;
}

async function deletePrefix(bucket: R2Bucket, fileId: string): Promise<void> {
  let cursor: string | undefined;
  do {
    const listed = await bucket.list({ prefix: `${fileId}/`, cursor });
    if (listed.objects.length > 0) {
      await bucket.delete(listed.objects.map((object) => object.key));
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
}

async function readOwner(
  bucket: R2Bucket,
  fileId: string,
  nowMs: number,
): Promise<string | null> {
  const object = await bucket.get(ownerKey(fileId));
  if (!object) return null;
  if (isExpired(object.uploaded.getTime(), nowMs)) {
    await object.body.cancel();
    // 绑定过期后整组对象一起清掉，避免旧块被新的绑定沿用。
    await deletePrefix(bucket, fileId);
    return null;
  }
  const sessionId = (await object.text()).trim();
  return RELAY_ID.test(sessionId) ? sessionId : null;
}

async function bindOwner(bucket: R2Bucket, fileId: string, sessionId: string): Promise<"created" | "same" | "other"> {
  const key = ownerKey(fileId);
  const created = await bucket.put(key, sessionId, {
    onlyIf: new Headers({ "if-none-match": "*" }),
  });
  if (created) return "created";
  const existing = await bucket.get(key);
  if (!existing) {
    await bucket.put(key, sessionId);
    return "created";
  }
  const bound = (await existing.text()).trim();
  return bound === sessionId ? "same" : "other";
}

type FileEnv = Pick<Env, "FILES" | "SESSIONS">;

async function account(
  env: FileEnv,
  sessionId: string,
  fileId: string,
  op: "put" | "get" | "delete",
  bytes: number,
  nowMs: number,
): Promise<Response | null> {
  const result = await authorizeSessionFile(env.SESSIONS, sessionId, { fileId, op, bytes, nowMs });
  if (result.ok) return null;
  return fail(result.error, result.status);
}

async function putChunk(
  request: Request,
  env: FileEnv,
  fileId: string,
  key: string,
  sessionId: string,
  nowMs: number,
): Promise<Response> {
  const body = await readBody(request, MAX_FILE_CHUNK_BYTES);
  if (!body) return fail("chunk-too-large", 413);
  if (body.byteLength === 0) return fail("empty-chunk");

  const owner = await readOwner(env.FILES, fileId, nowMs);
  if (owner && owner !== sessionId) return fail("forbidden", 403);
  if (!owner) {
    const bound = await bindOwner(env.FILES, fileId, sessionId);
    if (bound === "other") return fail("forbidden", 403);
  }

  const existing = await env.FILES.head(key);
  if (existing && !isExpired(existing.uploaded.getTime(), nowMs)) {
    const rated = await account(env, sessionId, fileId, "put", 0, nowMs);
    if (rated) return rated;
    return fail("chunk-exists", 409);
  }

  const billed = await account(env, sessionId, fileId, "put", body.byteLength, nowMs);
  if (billed) {
    // 这次是新绑定且一块都还没写成：把空绑定撤掉，以免占着 fileId。
    if (!owner) await env.FILES.delete(ownerKey(fileId));
    return billed;
  }

  // 只在对象不存在时写入，避免并发上传互相覆盖。
  const created = await env.FILES.put(key, body, {
    onlyIf: new Headers({ "if-none-match": "*" }),
  });
  if (!created) {
    // 并发下别人先写成了：撤回刚才加的占用，按已存在处理。
    const raced = await env.FILES.head(key);
    if (raced && !isExpired(raced.uploaded.getTime(), nowMs)) {
      await account(env, sessionId, fileId, "put", -body.byteLength, nowMs);
      return fail("chunk-exists", 409);
    }
    await env.FILES.put(key, body);
  }
  // 刷新绑定时间，使它不早于最后一块，避免“块还没到期、绑定先过期”。
  await env.FILES.put(ownerKey(fileId), sessionId);
  return ok(201);
}

async function getChunk(
  env: FileEnv,
  fileId: string,
  key: string,
  sessionId: string,
  nowMs: number,
): Promise<Response> {
  const owner = await readOwner(env.FILES, fileId, nowMs);
  if (!owner) return fail("not-found", 404);
  if (owner !== sessionId) return fail("forbidden", 403);
  const rated = await account(env, sessionId, fileId, "get", 0, nowMs);
  if (rated) return rated;

  const object = await env.FILES.get(key);
  if (!object) return fail("not-found", 404);
  if (isExpired(object.uploaded.getTime(), nowMs)) {
    await object.body.cancel();
    await env.FILES.delete(key);
    const leftover = await env.FILES.list({ prefix: `${fileId}/` });
    const chunks = leftover.objects.filter((item) => item.key !== ownerKey(fileId));
    if (chunks.length === 0) await env.FILES.delete(ownerKey(fileId));
    return fail("not-found", 404);
  }
  return new Response(object.body, {
    headers: { ...NO_STORE, "content-type": "application/octet-stream" },
  });
}

async function deleteFile(
  env: FileEnv,
  fileId: string,
  sessionId: string,
  nowMs: number,
): Promise<Response> {
  const owner = await readOwner(env.FILES, fileId, nowMs);
  if (!owner) return ok();
  if (owner !== sessionId) return fail("forbidden", 403);
  const rated = await account(env, sessionId, fileId, "delete", 0, nowMs);
  if (rated) return rated;
  await deletePrefix(env.FILES, fileId);
  return ok();
}

/**
 * `/file/` 下的请求。路径不属于 `/file/` 时返回 null，交给后面的路由。
 * nowMs 可注入，便于测试过期。
 */
export function handleFileRequest(
  request: Request,
  env: FileEnv,
  url: URL,
  nowMs: number = Date.now(),
): Response | Promise<Response> | null {
  const match = /^\/file\/([^/]+)(?:\/([^/]+))?$/.exec(url.pathname);
  if (!match) return null;
  const fileId = match[1];
  const indexText = match[2];

  if (!FILE_ID.test(fileId)) return fail("bad-file-id");
  if (indexText === undefined) {
    if (request.method !== "DELETE") return fail("method-not-allowed", 405);
    const auth = parseFileAuth(request);
    if (!auth) return fail("unauthorized", 401);
    return deleteFile(env, fileId, auth.sessionId, nowMs);
  }
  const index = parseChunkIndex(indexText);
  if (index === null) return fail("bad-chunk-index");
  if (request.method !== "PUT" && request.method !== "GET") {
    return fail("method-not-allowed", 405);
  }

  const auth = parseFileAuth(request);
  if (!auth) return fail("unauthorized", 401);

  const key = `${fileId}/${index}`;
  if (request.method === "PUT") return putChunk(request, env, fileId, key, auth.sessionId, nowMs);
  return getChunk(env, fileId, key, auth.sessionId, nowMs);
}
