# 任务：去掉不必要的 library 名称

## 目标
下列 9 个文件各有一条 `unnecessary_library_name` 告警（写了 `library xxx;`）。把它们改成不带名称的 `library;`，保留其上的文档注释。

## 文件
- `lib/contact/contact.dart`
- `lib/direct_text/direct_text.dart`
- `lib/e2ee/e2ee.dart`
- `lib/files/files.dart`
- `lib/identity/identity.dart`
- `lib/lan_discovery/lan_discovery.dart`
- `lib/pairing/pairing.dart`
- `lib/storage/storage.dart`
- `lib/voice/voice.dart`

## 具体要求
- 每个文件只改 `library xxx;` 这一行，改为 `library;`。
- 不改动 export、import 和其它任何代码。

## 验收
- `flutter analyze --no-pub --no-fatal-infos lib` 的输出中不再出现 `unnecessary_library_name`
- `flutter test --no-pub` 全部通过

## 不要做
- 不要修改上面列出的 9 个文件以外的任何文件
- 不要用 `// ignore:` 注释压掉告警
