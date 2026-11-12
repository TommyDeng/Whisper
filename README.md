# 耳语（Whisper）

只给亲友使用的私密通讯工具：端到端加密的文字聊天、语音通话和文件传输。Flutter 桌面客户端，首发 Linux 与 Windows；中继跑在 Cloudflare Workers 上，只转发密文。

产品需求见 [`docs/prd.md`](docs/prd.md)，技术架构见 [`docs/architecture.md`](docs/architecture.md)。安装包发布与校验见 [`docs/release.md`](docs/release.md)。

GPG 发布公钥指纹（所有者生成密钥后填在这里）：_待公布_。

本地检查：

```bash
flutter analyze --no-fatal-infos lib test
flutter test
# 改了 worker/ 时再跑：
cd worker && npm run typecheck && npm test
```

`spike/` 是早期验证代码，不参与上述检查，也不要改。
