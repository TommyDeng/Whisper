import { DurableObject } from "cloudflare:workers";

// 占位实现：协议见 docs/relay-protocol.md，由任务 relay-invite 完成。
export class InviteDO extends DurableObject<Env> {
  async fetch(_request: Request): Promise<Response> {
    return Response.json({ ok: false, error: "not-implemented" }, { status: 501 });
  }
}
