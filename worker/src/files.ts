// 文件中转：密文分块暂存在 R2（绑定 FILES，对象名 `<fileId>/<index>`）。约定见 docs/file-relay.md。
// 隐私：这里不记录任何请求信息（路径、fileId、大小、IP）。
import { FILE_ID, MAX_CHUNK_INDEX, MAX_FILE_CHUNK_BYTES, isExpired } from "./relay_limits";

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

async function putChunk(
  request: Request,
  bucket: R2Bucket,
  key: string,
  nowMs: number,
): Promise<Response> {
  const body = await readBody(request, MAX_FILE_CHUNK_BYTES);
  if (!body) return fail("chunk-too-large", 413);
  if (body.byteLength === 0) return fail("empty-chunk");

  // 只在对象不存在时写入，避免并发上传互相覆盖。
  const created = await bucket.put(key, body, {
    onlyIf: new Headers({ "if-none-match": "*" }),
  });
  if (created) return ok(201);

  // 已有的块若已过期，按不存在处理：换成新内容。
  const existing = await bucket.head(key);
  if (existing && !isExpired(existing.uploaded.getTime(), nowMs)) {
    return fail("chunk-exists", 409);
  }
  await bucket.put(key, body);
  return ok(201);
}

async function getChunk(bucket: R2Bucket, key: string, nowMs: number): Promise<Response> {
  const object = await bucket.get(key);
  if (!object) return fail("not-found", 404);
  if (isExpired(object.uploaded.getTime(), nowMs)) {
    await object.body.cancel();
    await bucket.delete(key);
    return fail("not-found", 404);
  }
  return new Response(object.body, {
    headers: { ...NO_STORE, "content-type": "application/octet-stream" },
  });
}

async function deleteFile(bucket: R2Bucket, fileId: string): Promise<Response> {
  let cursor: string | undefined;
  do {
    const listed = await bucket.list({ prefix: `${fileId}/`, cursor });
    if (listed.objects.length > 0) {
      await bucket.delete(listed.objects.map((object) => object.key));
    }
    cursor = listed.truncated ? listed.cursor : undefined;
  } while (cursor);
  return ok();
}

/**
 * `/file/` 下的请求。路径不属于 `/file/` 时返回 null，交给后面的路由。
 * nowMs 可注入，便于测试过期。
 */
export function handleFileRequest(
  request: Request,
  bucket: R2Bucket,
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
    return deleteFile(bucket, fileId);
  }
  const index = parseChunkIndex(indexText);
  if (index === null) return fail("bad-chunk-index");

  const key = `${fileId}/${index}`;
  if (request.method === "PUT") return putChunk(request, bucket, key, nowMs);
  if (request.method === "GET") return getChunk(bucket, key, nowMs);
  return fail("method-not-allowed", 405);
}
