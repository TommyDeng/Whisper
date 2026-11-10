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

/** 存入时间为 storedAtMs 的离线消息，在 nowMs 时是否已过期。 */
export function isExpired(storedAtMs: number, nowMs: number): boolean {
  return nowMs - storedAtMs >= OFFLINE_TTL_MS;
}
