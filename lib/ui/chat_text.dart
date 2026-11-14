/// 聊天文字：识别链接（可点击、右键可打开或复制），右键菜单是中文的。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_theme.dart';

/// 文字里的一段：普通文字，或一个链接。
class TextPiece {
  const TextPiece(this.text, {this.url});

  final String text;

  /// 链接要打开的地址；普通文字为 null。`www.` 开头的补上 `https://`。
  final String? url;

  bool get isLink => url != null;

  @override
  bool operator ==(Object other) =>
      other is TextPiece && other.text == text && other.url == url;

  @override
  int get hashCode => Object.hash(text, url);

  @override
  String toString() => url == null ? 'Text($text)' : 'Link($text → $url)';
}

/// `http://`、`https://` 或 `www.` 开头，直到空白或中文标点为止。
final RegExp _linkPattern = RegExp(
  r'''(?:https?://|www\.)[^\s<>"'`，。！？；：、（）【】《》“”‘’]+''',
  caseSensitive: false,
);

/// 链接末尾常见的英文标点多半是句子的，不算进链接；括号成对时保留。
String _trimTrailing(String link) {
  var end = link.length;
  while (end > 0) {
    final ch = link[end - 1];
    if ('.,;:!?'.contains(ch)) {
      end--;
      continue;
    }
    if (ch == ')') {
      final body = link.substring(0, end);
      final opens = '('.allMatches(body).length;
      final closes = ')'.allMatches(body).length;
      if (closes > opens) {
        end--;
        continue;
      }
    }
    break;
  }
  return link.substring(0, end);
}

/// 把 [text] 切成普通文字和链接。只认 http / https（含 `www.` 简写），别的协议不当链接。
List<TextPiece> splitLinks(String text) {
  final pieces = <TextPiece>[];
  var cursor = 0;
  for (final match in _linkPattern.allMatches(text)) {
    final link = _trimTrailing(match.group(0)!);
    // 只有 `www.` 或 `https://` 本身，不算链接。
    final host = link.replaceFirst(
      RegExp(r'^(https?://)?(www\.)?', caseSensitive: false),
      '',
    );
    if (host.isEmpty) continue;
    if (match.start > cursor) {
      pieces.add(TextPiece(text.substring(cursor, match.start)));
    }
    final url = link.toLowerCase().startsWith('www.') ? 'https://$link' : link;
    pieces.add(TextPiece(link, url: url));
    cursor = match.start + link.length;
  }
  if (cursor < text.length) pieces.add(TextPiece(text.substring(cursor)));
  return pieces;
}

/// 用系统浏览器打开 [url]；只放行 http / https。打不开时返回 false。
Future<bool> openExternalLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// 右键菜单里的文字。
const String kCopyLabel = '复制';
const String kSelectAllLabel = '全选';
const String kOpenLinkLabel = '打开链接';
const String kCopyLinkLabel = '复制链接';

/// 消息正文：可选中，链接高亮可点；右键弹出 复制 / 全选，鼠标在链接上时多出 打开链接 / 复制链接。
///
/// 没选中文字时「复制」复制整条消息。
class MessageText extends StatefulWidget {
  const MessageText(
    this.text, {
    super.key,
    required this.style,
    required this.linkColor,
    this.onLinkOpenFailed,
    this.openLink = openExternalLink,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  /// 链接没打开时调用，给用户提示。
  final VoidCallback? onLinkOpenFailed;

  /// 测试时替换。
  final Future<bool> Function(String url) openLink;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  late List<TextPiece> _pieces;
  final List<TapGestureRecognizer> _recognizers = [];

  /// 鼠标正停在哪个链接上（按地址记）；右键菜单据此给出链接选项。
  String? _hoveredUrl;

  /// 刚才右键时停在哪个链接上。菜单打开后鼠标会移开，所以按下右键那一刻记下来。
  String? _menuUrl;

  @override
  void initState() {
    super.initState();
    _rebuildPieces();
  }

  @override
  void didUpdateWidget(MessageText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _rebuildPieces();
  }

  void _rebuildPieces() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    _pieces = splitLinks(widget.text);
    for (final piece in _pieces) {
      if (!piece.isLink) continue;
      _recognizers.add(TapGestureRecognizer()..onTap = () => _open(piece.url!));
    }
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _setHovered(String? url) {
    if (!mounted || _hoveredUrl == url) return;
    setState(() => _hoveredUrl = url);
  }

  Future<void> _open(String url) async {
    final ok = await widget.openLink(url);
    if (!ok) widget.onLinkOpenFailed?.call();
  }

  TextSpan _buildSpan() {
    var linkIndex = 0;
    return TextSpan(
      style: widget.style,
      children: [
        for (final piece in _pieces)
          if (!piece.isLink)
            TextSpan(text: piece.text)
          else
            TextSpan(
              text: piece.text,
              recognizer: _recognizers[linkIndex++],
              mouseCursor: SystemMouseCursors.click,
              onEnter: (_) => _setHovered(piece.url),
              // 控件被移除时也会收到离开事件，那时已经不能 setState。
              onExit: (_) {
                if (_hoveredUrl == piece.url) _setHovered(null);
              },
              style: TextStyle(
                color: widget.linkColor,
                decoration: TextDecoration.underline,
                decorationColor: widget.linkColor.withValues(
                  alpha: _hoveredUrl == piece.url ? 1 : 0.5,
                ),
              ),
            ),
      ],
    );
  }

  Widget _contextMenu(BuildContext context, EditableTextState editable) {
    final selection = editable.textEditingValue.selection;
    final hasSelection = selection.isValid && !selection.isCollapsed;
    final url = _menuUrl;
    final items = <ContextMenuButtonItem>[
      if (url != null) ...[
        ContextMenuButtonItem(
          label: kOpenLinkLabel,
          onPressed: () {
            editable.hideToolbar();
            _open(url);
          },
        ),
        ContextMenuButtonItem(
          label: kCopyLinkLabel,
          onPressed: () {
            editable.hideToolbar();
            Clipboard.setData(ClipboardData(text: url));
          },
        ),
      ],
      ContextMenuButtonItem(
        label: kCopyLabel,
        onPressed: () {
          if (hasSelection) {
            editable.copySelection(SelectionChangedCause.toolbar);
          } else {
            Clipboard.setData(ClipboardData(text: widget.text));
            editable.hideToolbar();
          }
        },
      ),
      ContextMenuButtonItem(
        label: kSelectAllLabel,
        onPressed: () => editable.selectAll(SelectionChangedCause.toolbar),
      ),
    ];
    return TermContextMenu(
      anchor: editable.contextMenuAnchors.primaryAnchor,
      items: items,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kSecondaryMouseButton) _menuUrl = _hoveredUrl;
      },
      child: SelectableText.rich(
        _buildSpan(),
        contextMenuBuilder: _contextMenu,
      ),
    );
  }
}

/// 终端风格的右键菜单：面板底、细描边，每项悬停变亮。
class TermContextMenu extends StatelessWidget {
  const TermContextMenu({super.key, required this.anchor, required this.items});

  /// 菜单左上角（全局坐标）。
  final Offset anchor;
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: DesktopTextSelectionToolbarLayoutDelegate(anchor: anchor),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Motion.fast,
        curve: Motion.curve,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * -4),
            child: child,
          ),
        ),
        child: Container(
          constraints: const BoxConstraints(minWidth: 140),
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: const BoxDecoration(
            color: AppTheme.panel,
            borderRadius: AppTheme.corners,
            border: Border.fromBorderSide(BorderSide(color: AppTheme.border)),
            boxShadow: AppTheme.popupShadow,
          ),
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  _TermMenuItem(
                    label: item.label ?? '',
                    onPressed: item.onPressed,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TermMenuItem extends StatefulWidget {
  const _TermMenuItem({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  State<_TermMenuItem> createState() => _TermMenuItemState();
}

class _TermMenuItemState extends State<_TermMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: Motion.fast,
          color: _hovered ? AppTheme.accentSoft : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _hovered ? AppTheme.accent : AppTheme.text,
              fontSize: 13.5,
            ),
          ),
        ),
      ),
    );
  }
}
