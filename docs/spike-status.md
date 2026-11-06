# WebRTC Spike 状态（暂停快照）

> 记录时间：2026-11-02（东京时区）· 分支：`feat/webrtc-spike` · 最新提交：`087569367b090995c5582e418eb92930fd3a30c3` · PR：[#2](https://github.com/TommyDeng/Whisper/pull/2)

因 token 用尽，阶段二开发与测试于 2026-11-02 暂停，计划下周继续。本文件保存暂停时的验证结果与待修项，避免上下文丢失。

## 已通过

| 用例 | 路径 | 结果 |
|---|---|---|
| lan3 | 物理局域网 host↔host | 32 MiB，sha256 通过，约 9.76 MiB/s，0 次重传，角色正确 |
| zt01 | ZeroTier-only，数据通道（`SPIKE_ONLY_TIER=zerotier`） | 32 MiB，sha256 通过，约 0.81 MiB/s，0 次重传；慢主要因 SCTP 叠在 ZeroTier MTU 2800 上 |

## 未通过 / 未完成

| 用例 | 问题摘要 |
|---|---|
| zt02 / zt03 | `SPIKE_FILE_TRANSPORT=direct`（ZeroTier 直连 TCP）仍失败。涉及 offerer 直连就绪竞态、回退数据通道时的停滞钟、Windows 网卡探测超时、hold 结束后 RST 等。直连路径累计失败 2 次（门禁为同一 bug 连续 5 次） |
| TURN | 尚未专项测试 |

## 暂停时取消中的修复方向（未合入）

以下为 zt03 后拟定、因暂停未提交的修复方向，恢复工作时优先处理：

1. 加固 offerer 侧「直连未就绪」等待逻辑  
2. 回退到数据通道时，停滞钟计入发送进度  
3. 结果 JSON 写出后不再接受新会话  
4. 加固 Windows 网卡探测  
5. 处理 prflx 远端候选  
6. 增加 `SPIKE_LOG` 详细日志  
7. 增加「对端延迟加入」用例  

## 测试机快照（暂停时）

| 机器 | 局域网 | ZeroTier | 备注 |
|---|---|---|---|
| Ubuntu | 192.168.31.236 | 10.30.249.243 | ufw 关闭；`wrangler dev` 信令曾常驻 `0.0.0.0:8787` |
| Windows | 192.168.31.180 | 10.30.249.106 | 客户端目录 `C:\Users\Tommy\whisper-test\` |

## 恢复工作建议顺序

1. 按上文修复直连 TCP 相关竞态与探测问题，推到 `feat/webrtc-spike`  
2. 重跑 ZeroTier 直连（建议房间名 `zt04`）  
3. 再跑 TURN 专项  
4. 双机验证通过后再考虑合并 PR #2  

## 说明

当前产物是 **连接与传文件探针**，不是可日常使用的耳语客户端（无账号、联系人、邀请码、聊天历史）。大文件直连通道有已知 bug，日常试用请走数据通道。
