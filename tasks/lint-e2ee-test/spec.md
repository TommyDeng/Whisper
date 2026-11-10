# 任务：清理 test/e2ee_security_test.dart 的静态分析告警

## 目标
`flutter analyze test/e2ee_security_test.dart` 目前报 6 条 info，全部来自导入写法和文件头注释。把它们清零，不改变任何测试逻辑。

## 具体要求
- 把 `../lib/...` 相对导入改成 `package:whisper/...` 导入（包名见 `pubspec.yaml`）。
- 删除多余的导入（`identity/safety_code.dart` 已由 `identity/identity.dart` 导出）。
- 修复文件头的 dangling library doc comment（改成普通 `//` 注释，或加 `library;` 指令，二选一）。
- 测试用例的名称、数量、断言一律不动。

## 验收
- `flutter analyze --fatal-infos test/e2ee_security_test.dart` 输出 `No issues found!`
- `flutter test` 全部通过，用例总数不少于修改前（33 个）

## 不要做
- 不要修改 `test/e2ee_security_test.dart` 以外的任何文件
- 不要用 `// ignore:` 注释压掉告警
