// 会话中继（SessionDO）与配对（InviteDO）共用的常量。协议见 docs/relay-protocol.md。

/** 会话 ID / 邀请 ID：URL 安全字符，22–64 个（16 字节随机数的 base64url 为 22 个字符）。 */
export const RELAY_ID = /^[A-Za-z0-9_-]{22,64}$/;

/** 配对连接的 key：客户端本地随机生成，用于在重连时证明“还是同一个邀请人 / 加入者”。 */
export const INVITE_KEY = /^[A-Za-z0-9_-]{16,64}$/;

/** 消息 ID：客户端生成。 */
export const MESSAGE_ID = /^[A-Za-z0-9_-]{1,64}$/;

/** 单帧（整条 WebSocket 文本）的最大字符数。 */
export const MAX_FRAME_CHARS = 128 * 1024;

/** msg.payload 的最大字符数。 */
export const MAX_PAYLOAD_CHARS = 64 * 1024;

/** 配对请求 / 应答 payload 的最大字符数。 */
export const MAX_PAIR_PAYLOAD_CHARS = 8 * 1024;

/** 每个接收方最多排队的离线消息数。 */
export const MAX_QUEUED_PER_PEER = 1000;

/** 每条连接的限速：窗口内最多处理的帧数。 */
export const RATE_LIMIT_WINDOW_MS = 10_000;
export const RATE_LIMIT_MAX_FRAMES = 120;

/** 离线消息最长保留 7 天（毫秒）。 */
export const OFFLINE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** 邀请最长有效期 24 小时（毫秒），另给客户端时钟 5 分钟的误差余量。 */
export const INVITE_MAX_TTL_MS = 24 * 60 * 60 * 1000;
export const INVITE_CLOCK_SKEW_MS = 5 * 60 * 1000;

/** 文件 ID：32 字节随机数的 base64url（无填充），正好 43 个 URL 安全字符。见 docs/file-relay.md。 */
export const FILE_ID = /^[A-Za-z0-9_-]{43}$/;

/** 文件块序号的上限（含）。 */
export const MAX_CHUNK_INDEX = 127;

/** 单个密文块的最大字节数：1 MiB 明文 + 16 字节认证标签。 */
export const MAX_FILE_CHUNK_BYTES = 1024 * 1024 + 16;

/** 存入时间为 storedAtMs 的离线消息或文件块，在 nowMs 时是否已过期。 */
export function isExpired(storedAtMs: number, nowMs: number): boolean {
  return nowMs - storedAtMs >= OFFLINE_TTL_MS;
}

/** 每个会话当前占用的文件密文上限（1 GiB）。见 docs/file-relay.md。 */
export const FILE_SESSION_QUOTA_BYTES = 1024 * 1024 * 1024;

/** 每个会话的文件接口限速：窗口内最多处理的请求次数（PUT/GET/DELETE 都计数）。 */
export const FILE_RATE_LIMIT_WINDOW_MS = 10_000;
export const FILE_RATE_LIMIT_MAX_REQUESTS = 60;
