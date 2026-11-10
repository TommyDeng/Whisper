# 任务：删除 lib/ui/contacts_list.dart 中多余的导入

## 目标
`flutter analyze` 对 `lib/ui/contacts_list.dart` 报 3 条 `unnecessary_import`：`contact_model.dart`、`contact_store.dart` 已由 `../contact/contact.dart` 导出，`identity_store.dart` 已由 `../identity/identity.dart` 导出。删掉这 3 条多余导入。

## 具体要求
- 只删除这 3 行 import，不改动其它代码。

## 验收
- `flutter analyze --no-pub --fatal-infos lib/ui/contacts_list.dart` 输出 `No issues found!`
- `flutter test --no-pub` 全部通过

## 不要做
- 不要修改 `lib/ui/contacts_list.dart` 以外的任何文件
- 不要用 `// ignore:` 注释压掉告警
