import { DurableObject } from "cloudflare:workers";

// 占位实现：协议见 docs/relay-protocol.md，由任务 relay-session 完成。
export class SessionDO extends DurableObject<Env> {
  async fetch(_request: Request): Promise<Response> {
    return Response.json({ ok: false, error: "not-implemented" }, { status: 501 });
  }
}
