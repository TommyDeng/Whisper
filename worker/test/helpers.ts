import { exports } from "cloudflare:workers";

export type Frame = Record<string, unknown>;

/** 22 个 URL 安全字符，满足 RELAY_ID / INVITE_KEY。 */
export function randomId(): string {
  return crypto.randomUUID().replaceAll("-", "").slice(0, 22);
}

/** 测试用 WebSocket 客户端：收到的帧先进缓冲，不会因为没来得及监听而丢。 */
export class Client {
  private readonly queue: Frame[] = [];
  private readonly waiters: ((frame: Frame) => void)[] = [];
  readonly closed: Promise<{ code: number; reason: string }>;

  constructor(readonly ws: WebSocket) {
    this.closed = new Promise((resolve) => {
      ws.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
    });
    ws.addEventListener("message", (event) => {
      const frame = JSON.parse(String(event.data)) as Frame;
      const waiter = this.waiters.shift();
      if (waiter) waiter(frame);
      else this.queue.push(frame);
    });
    ws.accept();
  }

  /** 下一帧（任何类型）。 */
  next(timeoutMs = 4000): Promise<Frame> {
    const queued = this.queue.shift();
    if (queued) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const waiter = (frame: Frame): void => {
        clearTimeout(timer);
        resolve(frame);
      };
      const timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        reject(new Error("timed out waiting for a frame"));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  /** 下一帧，跳过 peer-online / peer-offline。 */
  async nextData(): Promise<Frame> {
    for (;;) {
      const frame = await this.next();
      if (frame.type !== "peer-online" && frame.type !== "peer-offline") return frame;
    }
  }

  /** 等 ms 毫秒，返回这段时间结束时缓冲里的全部帧。 */
  async drain(ms = 200): Promise<Frame[]> {
    await new Promise((resolve) => setTimeout(resolve, ms));
    return this.queue.splice(0);
  }

  send(frame: unknown): void {
    this.ws.send(typeof frame === "string" ? frame : JSON.stringify(frame));
  }

  /** 发 ping，并断言紧接着收到的数据帧就是 pong（即此前没有别的数据帧在路上）。 */
  async expectNothingPending(): Promise<void> {
    this.send({ type: "ping" });
    const frame = await this.nextData();
    if (frame.type !== "pong") {
      throw new Error(`expected pong, got ${JSON.stringify(frame)}`);
    }
  }

  close(): void {
    this.ws.close(1000, "done");
  }
}

export function request(path: string, upgrade = true): Promise<Response> {
  return exports.default.fetch(`http://example.com${path}`, {
    headers: upgrade ? { Upgrade: "websocket" } : {},
  });
}

export async function connect(path: string): Promise<Client> {
  const response = await request(path);
  if (response.status !== 101 || !response.webSocket) {
    throw new Error(`upgrade failed: ${response.status} ${await response.text()}`);
  }
  return new Client(response.webSocket);
}
