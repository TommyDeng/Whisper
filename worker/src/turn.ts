// TURN 临时凭据：用 Cloudflare Realtime TURN 密钥换一组短期 ICE 服务器配置。
// 长期密钥（TURN_KEY_ID / TURN_KEY_API_TOKEN）只存在 Worker 的 secret 里，不下发给客户端。
// 不记录任何请求信息或凭据。

export interface TurnEnv {
  TURN_KEY_ID?: string;
  TURN_KEY_API_TOKEN?: string;
}

export interface IceServer {
  urls: string[];
  username?: string;
  credential?: string;
}

export type TurnResult =
  | { ok: true; iceServers: IceServer[] }
  | { ok: false; status: 501 | 502; error: string };

/** 凭据有效期：要比最长的一通通话长。 */
export const TURN_TTL_SECONDS = 4 * 60 * 60;

const UPSTREAM_TIMEOUT_MS = 5000;
const ALLOWED_SCHEMES = ["stun:", "turn:", "turns:"];

type Fetcher = (input: string, init: RequestInit) => Promise<Response>;

function cleanUrls(value: unknown): string[] {
  const list = typeof value === "string" ? [value] : Array.isArray(value) ? value : [];
  return list.filter(
    (url): url is string =>
      typeof url === "string" &&
      url.length <= 200 &&
      ALLOWED_SCHEMES.some((scheme) => url.startsWith(scheme)) &&
      // 53 端口常被拦截，留着只会让客户端白等超时
      !/:53(\?|$)/.test(url),
  );
}

/** 只保留认识的字段，上游多给的东西不转发。 */
export function cleanIceServers(body: unknown): IceServer[] {
  if (typeof body !== "object" || body === null) return [];
  const raw = (body as { iceServers?: unknown }).iceServers;
  // 上游有时返回单个对象而不是数组
  const list = Array.isArray(raw) ? raw : typeof raw === "object" && raw !== null ? [raw] : [];
  const servers: IceServer[] = [];
  for (const item of list) {
    if (typeof item !== "object" || item === null) continue;
    const { urls, username, credential } = item as Record<string, unknown>;
    const cleaned = cleanUrls(urls);
    if (cleaned.length === 0) continue;
    const server: IceServer = { urls: cleaned };
    if (typeof username === "string" && typeof credential === "string") {
      server.username = username;
      server.credential = credential;
    }
    servers.push(server);
  }
  return servers;
}

export async function issueTurnCredentials(
  env: TurnEnv,
  fetcher: Fetcher = (input, init) => fetch(input, init),
): Promise<TurnResult> {
  const keyId = env.TURN_KEY_ID ?? "";
  const token = env.TURN_KEY_API_TOKEN ?? "";
  if (!keyId || !token) return { ok: false, status: 501, error: "turn-not-configured" };

  let response: Response;
  try {
    response = await fetcher(
      `https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyId)}/credentials/generate-ice-servers`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
        body: JSON.stringify({ ttl: TURN_TTL_SECONDS }),
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      },
    );
  } catch {
    return { ok: false, status: 502, error: "turn-upstream-unreachable" };
  }
  if (!response.ok) return { ok: false, status: 502, error: "turn-upstream-error" };

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return { ok: false, status: 502, error: "turn-upstream-error" };
  }
  const iceServers = cleanIceServers(body);
  if (!iceServers.some((server) => server.username !== undefined)) {
    return { ok: false, status: 502, error: "turn-upstream-error" };
  }
  return { ok: true, iceServers };
}
