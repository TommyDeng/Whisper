/// 接收从系统文件管理器拖进窗口的文件。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

/// `flutter test` 里没有原生拖放插件，跳过拖放区域，只渲染 [child]。
final bool kFileDropSupported = !Platform.environment.containsKey(
  'FLUTTER_TEST',
);

/// 把 [child] 变成拖放目标：拖着文件进入时 [onHover] 给 true，离开或松手后给 false；
/// 松手时每个文件的本地路径依次交给 [onFile]（不在本地的条目忽略）。
class FileDropTarget extends StatelessWidget {
  const FileDropTarget({
    super.key,
    required this.child,
    required this.onHover,
    required this.onFile,
    this.enabled,
  });

  final Widget child;
  final ValueChanged<bool> onHover;
  final ValueChanged<String> onFile;

  /// 为 null 时按 [kFileDropSupported]。
  final bool? enabled;

  @override
  Widget build(BuildContext context) {
    if (!(enabled ?? kFileDropSupported)) return child;
    return DropRegion(
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) =>
          event.session.allowedOperations.contains(DropOperation.copy)
          ? DropOperation.copy
          : DropOperation.none,
      onDropEnter: (_) => onHover(true),
      onDropLeave: (_) => onHover(false),
      onPerformDrop: (event) async {
        for (final item in event.session.items) {
          final reader = item.dataReader;
          if (reader == null || !reader.canProvide(Formats.fileUri)) continue;
          reader.getValue<Uri>(Formats.fileUri, (uri) {
            if (uri != null && uri.isScheme('file')) onFile(uri.toFilePath());
          }, onError: (_) {});
        }
      },
      child: child,
    );
  }
}
