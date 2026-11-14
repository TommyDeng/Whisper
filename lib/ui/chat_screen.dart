/// 耳语 Whisper - 聊天界面
///
/// 1:1 E2EE 文字聊天。安全状态常驻显示在标题栏。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide MessageCodec;
import 'package:path/path.dart' as p;

import '../app_services.dart';
import '../contact/contact.dart';
import '../files/file_send_plan.dart';
import '../files/file_share_service.dart';
import '../messaging/message_codec.dart';
import '../messaging/messaging_service.dart';
import '../relay/session_client.dart';
import 'app_theme.dart';
import 'chat_text.dart';
import 'clipboard_image.dart';
import 'file_transfer_ui.dart';

/// 聊天气泡
class ChatBubble extends StatelessWidget {
  final String? text;
  final Widget? child;
  final bool isSent;

  /// 自己发出的消息的状态；收到的消息为 null。
  final OutgoingStatus? status;

  /// 阅后即焚的消息：对方读过之后两边都会删除。
  final bool burn;

  const ChatBubble({
    super.key,
    this.text,
    this.child,
    required this.isSent,
    this.status,
    this.burn = false,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, tooltip, color) = switch (status) {
      OutgoingStatus.sending => (Icons.schedule, '发送中', AppTheme.text3),
      OutgoingStatus.sent => (Icons.done, '已发送', AppTheme.text3),
      OutgoingStatus.delivered => (Icons.done_all, '已送达', AppTheme.text2),
      OutgoingStatus.failed => (Icons.error_outline, '发送失败', AppTheme.alert),
      null => (Icons.done, '', AppTheme.text3),
    };
    const burnMark = Tooltip(
      message: '阅后即焚：读过之后两边都会删除',
      child: Icon(
        Icons.local_fire_department_outlined,
        size: 14,
        color: AppTheme.alert,
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: isSent
          ? MainAxisAlignment.end
          : MainAxisAlignment.start,
      children: [
        // 自己发的：阅后即焚标记和发送状态在气泡左边，贴着气泡。
        if (isSent && burn) ...[burnMark, const SizedBox(width: 4)],
        if (isSent && status != null) ...[
          Tooltip(
            message: tooltip,
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Container(
            constraints: BoxConstraints(
              // 宽窗口里气泡不跟着无限变宽，一行太长不好读。
              maxWidth: math.min(MediaQuery.of(context).size.width * 0.7, 560),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: isSent ? AppTheme.sentBg : AppTheme.raised,
              borderRadius: AppTheme.corners,
              border: Border.all(
                color: isSent ? AppTheme.accent : AppTheme.border,
              ),
              boxShadow: isSent ? AppTheme.glow : null,
            ),
            child:
                child ??
                MessageText(
                  text ?? '',
                  style: TextStyle(
                    color: isSent ? AppTheme.sentText : AppTheme.text,
                    fontSize: 14.5,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                  ),
                  linkColor: AppTheme.accent,
                  onLinkOpenFailed: () => ScaffoldMessenger.maybeOf(context)
                      ?.showSnackBar(const SnackBar(content: Text('无法打开这个链接'))),
                ),
          ),
        ),
        if (!isSent && burn) ...[const SizedBox(width: 6), burnMark],
      ],
    );
  }
}

/// 聊天界面
class ChatScreen extends StatefulWidget {
  final String contactName;
  final Contact contact;

  /// 下面几个参数只给测试用：正式界面走 [AppServices] 和系统对话框。
  final MessagingService? messaging;
  final FileShareService? files;
  final FileLocationPicker? filePicker;
  final Future<void> Function(String path)? revealFile;

  /// 用系统程序打开文件（播放视频）；测试时替换。
  final Future<void> Function(String path)? openFile;
  final Future<bool> Function(String path)? copyImage;

  /// 单栏时给：标题栏左边出现返回按钮。分栏时不给。
  final VoidCallback? onBack;

  /// 把收到的消息标成已读之后调用，联系人列表用它刷新未读数。
  final VoidCallback? onRead;

  const ChatScreen({
    super.key,
    required this.contactName,
    required this.contact,
    this.messaging,
    this.files,
    this.filePicker,
    this.revealFile,
    this.openFile,
    this.copyImage,
    this.onBack,
    this.onRead,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final MessagingService _messaging =
      widget.messaging ?? AppServices.instance.messaging;
  late final FileShareService _files =
      widget.files ?? AppServices.instance.files;
  late final FileLocationPicker _picker =
      widget.filePicker ?? const DesktopFileLocationPicker();

  final _textController = TextEditingController();
  final _focusNode = FocusNode();
  StreamSubscription<String>? _messageSub;
  StreamSubscription<String>? _fileSub;
  List<ChatMessage> _messages = [];
  Map<String, String> _localPaths = {};
  late bool _verified = widget.contact.isVerified;
  late bool _burn = widget.contact.burnAfterRead;
  bool _isLoading = true;
  bool _reloading = false;
  bool _reloadAgain = false;

  String get _sessionId => widget.contact.sessionId;

  SecurityStatus get _security =>
      _verified ? SecurityStatus.verified : SecurityStatus.unverified;

  @override
  void initState() {
    super.initState();
    _messageSub = _messaging.updates.listen((sessionId) {
      if (sessionId == _sessionId) unawaited(_loadMessages());
    });
    _fileSub = _files.updates.listen((sessionId) {
      if (sessionId != _sessionId) return;
      // 进度在内存里，先刷新；本地路径是异步读库，稍后再补。
      if (mounted) setState(() {});
      unawaited(_loadLocalPaths());
    });
    unawaited(_loadMessages());
    unawaited(_loadLocalPaths());
    AppServices.instance.uiFocus.enterSession(_sessionId);
  }

  @override
  void dispose() {
    AppServices.instance.uiFocus.leaveSession(_sessionId);
    unawaited(_messageSub?.cancel());
    unawaited(_fileSub?.cancel());
    // 离开聊天时，读过的阅后即焚消息从本机删除
    unawaited(
      _messaging
          .purgeBurned(sessionId: _sessionId)
          .then<void>((_) {}, onError: (_) {}),
    );
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 重新读取消息。更新来得很密时合并成一次接一次，不并发读库。
  Future<void> _loadMessages() async {
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        List<ChatMessage> messages;
        try {
          messages = await _messaging.messages(widget.contact);
        } catch (_) {
          messages = _messages;
        }
        Map<String, String> paths = _localPaths;
        try {
          paths = await _files.localPaths(_sessionId);
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _messages = messages;
          _localPaths = paths;
          _isLoading = false;
        });
        // 消息已经显示在屏幕上，算读过；阅后即焚的会通知对方删除
        if (messages.any((message) => !message.isSent)) {
          try {
            await _messaging.markRead(widget.contact);
            widget.onRead?.call();
          } catch (_) {
            // 标记失败不影响显示，下次刷新再试
          }
          if (!mounted) return;
        }
      } while (_reloadAgain);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _loadLocalPaths() async {
    Map<String, String> paths;
    try {
      paths = await _files.localPaths(_sessionId);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _localPaths = paths);
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    _focusNode.requestFocus();
    try {
      await _messaging.sendText(widget.contact, text, burn: _burn);
    } on ArgumentError {
      _textController.text = text;
      _toast('消息太长了（上限约 ${MessageCodec.maxTextBytes ~/ 1024} KB），请分几条发。');
    } catch (_) {
      _textController.text = text;
      _toast('发送失败，请稍后再试。');
    }
  }

  Future<void> _sendFile() async {
    if (_burn) return;
    final String? path;
    try {
      path = await _picker.pickSource();
    } catch (_) {
      _toast('无法打开文件选择框。');
      return;
    }
    if (!mounted || path == null || path.isEmpty) return;
    await _sendFileFromPath(path);
  }

  /// 把已有文件（选文件或粘贴的图片）按当前在线情况发出去。
  Future<void> _sendFileFromPath(String path) async {
    if (_burn) return;
    final file = File(path);
    int size;
    try {
      size = await file.length();
    } on FileSystemException {
      size = 0;
    }

    final online = _messaging.peerOnline(_sessionId);
    final plan = planFileSend(
      size: size,
      peerOnline: online,
      directAvailable: true,
    );
    await _followFilePlan(plan, file, size);
  }

  void _insertClipboardText(String value) {
    final current = _textController;
    final selection = current.selection;
    final text = current.text;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final next = text.replaceRange(start, end, value);
    current.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  /// Ctrl+V：剪贴板是图片就当文件发（阅后即焚时不发文件），否则插入文字。
  Future<void> _pasteIntoChat() async {
    if (!_burn) {
      try {
        // 存到应用自己的图片目录：放系统临时目录的话重启后气泡里的图就没了。
        final file = await saveClipboardImage(
          directory: await AppServices.instance.chatImages.directory(),
        );
        if (file != null) {
          await _sendFileFromPath(file.path);
          return;
        }
      } catch (_) {
        // 读图失败时退回粘贴文字。
      }
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _insertClipboardText(text);
  }

  Future<void> _followFilePlan(FileSendPlan plan, File file, int size) async {
    switch (plan.action) {
      case FileSendAction.tooLarge:
        _toast(fileTransferErrorText('too-large-direct'));
        return;
      case FileSendAction.direct:
        await _files.sendDirect(widget.contact, file);
        if (!mounted) return;
        await _maybeFallbackToRelay(file, size);
        return;
      case FileSendAction.relayConfirm:
        final confirmed = await confirmRelaySend(
          context,
          reason: plan.reason ?? 'offline',
          size: size,
        );
        if (!confirmed || !mounted) return;
        await _files.sendViaRelay(widget.contact, file);
        return;
      case FileSendAction.relayUnavailable:
        await showRelayUnavailable(
          context,
          reason: plan.reason ?? 'offline',
          size: size,
        );
        return;
    }
  }

  /// 直传因为对方离线或没有点对点直连失败时，再问用户要不要改走中转。
  Future<void> _maybeFallbackToRelay(File file, int size) async {
    final failed = _files
        .uploads(_sessionId)
        .where((state) => state.isDirect && canFallbackToRelay(state.error))
        .toList();
    if (failed.isEmpty) return;
    final state = failed.last;
    final reason = state.error!;
    _files.cancel(state.id);
    if (!mounted) return;
    final plan = planFileSend(
      size: size,
      peerOnline: false,
      directFailure: reason,
    );
    await _followFilePlan(plan, file, size);
  }

  Future<void> _acceptIncoming(FileTransferState state) async {
    final String? path;
    try {
      path = await _picker.pickSavePath(suggestedName: state.name);
    } catch (_) {
      _toast('无法打开保存对话框。');
      return;
    }
    if (!mounted || path == null || path.isEmpty) return;
    final target = File(path);
    try {
      if (await target.exists()) {
        if (!mounted) return;
        final overwrite = await confirmOverwrite(
          context,
          p.basename(target.path),
        );
        if (!mounted || !overwrite) return;
      }
    } on FileSystemException {
      _toast('无法访问所选的保存位置。');
      return;
    }
    await _files.acceptIncoming(state.id, target);
  }

  Future<void> _download(ChatMessage message) async {
    final offer = message.file;
    if (offer == null) return;
    final String? path;
    try {
      path = await _picker.pickSavePath(suggestedName: offer.safeName);
    } catch (_) {
      _toast('无法打开保存对话框。');
      return;
    }
    if (!mounted || path == null || path.isEmpty) return;
    final target = File(path);
    try {
      if (await target.exists()) {
        if (!mounted) return;
        final overwrite = await confirmOverwrite(
          context,
          p.basename(target.path),
        );
        if (!mounted || !overwrite) return;
      }
    } on FileSystemException {
      _toast('无法访问所选的保存位置。');
      return;
    }
    await _files.download(widget.contact, message, target);
  }

  Future<void> _reveal(String path) async {
    final reveal = widget.revealFile ?? revealFileInFolder;
    try {
      await reveal(path);
    } catch (_) {
      _toast('无法打开所在位置。');
    }
  }

  Future<void> _openFile(String path) async {
    final open = widget.openFile ?? openFileWithSystem;
    try {
      await open(path);
    } catch (_) {
      _toast('无法打开这个文件。');
    }
  }

  Future<void> _copyImage(String path) async {
    final copy = widget.copyImage ?? copyImageFileToClipboard;
    final ok = await copy(path);
    if (ok) {
      _toast('已复制图片', error: false);
    } else {
      _toast('复制图片失败。');
    }
  }

  Future<void> _saveImage(String path, String name) async {
    final String? chosen;
    try {
      chosen = await _picker.pickSavePath(suggestedName: name);
    } catch (_) {
      _toast('无法打开保存对话框。');
      return;
    }
    if (!mounted || chosen == null || chosen.isEmpty) return;
    final target = File(chosen);
    try {
      if (p.equals(target.absolute.path, File(path).absolute.path)) {
        _toast('已保存图片', error: false);
        return;
      }
      if (await target.exists()) {
        if (!mounted) return;
        final overwrite = await confirmOverwrite(
          context,
          p.basename(target.path),
        );
        if (!mounted || !overwrite) return;
      }
      await File(path).copy(target.path);
    } on FileSystemException {
      _toast('保存图片失败。');
      return;
    }
    _toast('已保存图片', error: false);
  }

  bool _pathMissing(String? path) {
    if (path == null) return false;
    try {
      return !File(path).existsSync();
    } on FileSystemException {
      return true;
    }
  }

  void _toast(String text, {bool error = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? AppTheme.alertSoft : null,
        shape: error
            ? const RoundedRectangleBorder(
                borderRadius: AppTheme.corners,
                side: BorderSide(color: AppTheme.alert),
              )
            : null,
      ),
    );
  }

  Future<void> _showSafetyCode() async {
    final verified = await showTermDialog<bool>(
      context: context,
      builder: (context) => TermDialog(
        title: '安全码',
        tag: 'VERIFY_',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('通过电话或当面，和对方核对这串安全码。两边一致，说明没有人冒充对方。'),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.field,
                borderRadius: AppTheme.corners,
                border: Border.all(color: AppTheme.border),
              ),
              child: SelectableText(
                widget.contact.safetyCode,
                textAlign: TextAlign.center,
                style: AppTheme.mono(
                  color: _verified ? AppTheme.accent : AppTheme.amber,
                  size: 15,
                  weight: FontWeight.w600,
                  letterSpacing: 1.5,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          if (_verified)
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消已验证标记'),
            )
          else
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('已核对一致'),
            ),
        ],
      ),
    );
    if (verified == null) return;
    await ContactStore.updateContactVerification(
      widget.contact.deviceId,
      verified,
    );
    if (mounted) setState(() => _verified = verified);
  }

  Future<void> _toggleBurn() async {
    final enabled = !_burn;
    await ContactStore.updateContactBurnAfterRead(
      widget.contact.deviceId,
      enabled,
    );
    if (!mounted) return;
    setState(() => _burn = enabled);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          enabled
              ? '阅后即焚已开启：之后你发出的消息，对方读过后两边都会删除。'
              : '阅后即焚已关闭。已经发出的阅后即焚消息不受影响。',
        ),
      ),
    );
  }

  String get _linkText {
    switch (_messaging.linkState(_sessionId)) {
      case SessionLinkState.connected:
        return _messaging.peerOnline(_sessionId)
            ? '对方在线'
            : '对方不在线，消息会在 7 天内等对方上线';
      case SessionLinkState.connecting:
        return '正在连接…';
      case SessionLinkState.disconnected:
        return '未连接，消息会在连上后发出';
    }
  }

  Future<void> _startCall() async {
    try {
      await AppServices.instance.calls.start(widget.contact);
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已有一通通话在进行')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final uploads = _files.uploads(_sessionId);
    final incoming = _files.incoming(_sessionId);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildMessages()),
          for (final state in uploads)
            FileUploadTile(
              key: ValueKey('upload-${state.id}'),
              name: state.name,
              done: state.done,
              total: state.total,
              error: state.error,
              isDirect: state.isDirect,
              onCancel: () => _files.cancel(state.id),
            ),
          for (final state in incoming)
            FileIncomingTile(
              key: ValueKey('incoming-${state.id}'),
              name: state.name,
              size: state.total,
              done: state.done,
              total: state.total,
              error: state.error,
              needsAccept: state.needsAccept,
              onAccept: state.needsAccept
                  ? () => unawaited(_acceptIncoming(state))
                  : null,
              onDecline: state.needsAccept
                  ? () => _files.declineIncoming(state.id)
                  : null,
              onCancel: state.needsAccept
                  ? null
                  : () => _files.cancel(state.id),
            ),
          _buildComposer(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final online = _messaging.peerOnline(_sessionId);
    return Container(
      height: 64,
      padding: EdgeInsets.only(left: widget.onBack == null ? 24 : 8, right: 12),
      decoration: const BoxDecoration(
        color: AppTheme.panel,
        border: Border(bottom: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        children: [
          if (widget.onBack != null) ...[
            TermIconButton(
              tooltip: '返回',
              icon: Icons.arrow_back,
              onPressed: widget.onBack,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: '查看安全码',
                child: InkWell(
                  onTap: _showSafetyCode,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ContactMark(
                        name: widget.contactName,
                        online: online,
                        size: 36,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.contactName,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.text,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SecurityIcon(status: _security, size: 14),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_verified ? '已验证' : '未验证'} · $_linkText',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _verified
                                    ? AppTheme.text2
                                    : AppTheme.amber,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SquareIconButton(
            tooltip: '语音通话',
            icon: Icons.call_outlined,
            onPressed: () => unawaited(_startCall()),
          ),
          const SizedBox(width: 4),
          TermIconButton(
            tooltip: _burn ? '关闭阅后即焚' : '开启阅后即焚',
            icon: _burn
                ? Icons.local_fire_department
                : Icons.local_fire_department_outlined,
            color: _burn ? AppTheme.alert : AppTheme.text2,
            onPressed: () => unawaited(_toggleBurn()),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 16),
      child: Row(
        children: [
          TermIconButton(
            tooltip: _burn ? kBurnDisablesFileSend : '发送文件',
            icon: Icons.attach_file,
            onPressed: _burn ? null : () => unawaited(_sendFile()),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyV,
                  control: true,
                ): () =>
                    unawaited(_pasteIntoChat()),
                const SingleActivator(
                  LogicalKeyboardKey.keyV,
                  meta: true,
                ): () =>
                    unawaited(_pasteIntoChat()),
              },
              child: TextField(
                controller: _textController,
                focusNode: _focusNode,
                autofocus: true,
                style: const TextStyle(color: AppTheme.text, fontSize: 14.5),
                decoration: InputDecoration(
                  hintText: _burn ? '输入消息（阅后即焚）' : '输入消息',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 11),
                  // 终端提示符。
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 14, right: 8),
                    child: Text(
                      '>',
                      style: AppTheme.mono(
                        color: AppTheme.accent,
                        size: 14.5,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(),
                  suffixIcon: Padding(
                    padding: const EdgeInsets.all(6),
                    child: SquareIconButton(
                      tooltip: '发送',
                      icon: Icons.arrow_upward,
                      size: 28,
                      iconSize: 16,
                      background: AppTheme.accent,
                      foreground: AppTheme.onAccent,
                      onPressed: () => unawaited(_sendMessage()),
                    ),
                  ),
                  suffixIconConstraints: const BoxConstraints(),
                ),
                maxLines: 1,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => unawaited(_sendMessage()),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessages() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, size: 32, color: AppTheme.text3),
            SizedBox(height: 14),
            Text(
              '暂无消息',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              '消息端到端加密，只有你们两人能看到',
              style: TextStyle(color: AppTheme.text2, fontSize: 12.5),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      reverse: true,
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[_messages.length - 1 - index];
        final file = message.file;
        if (file != null) {
          final path = _localPaths[message.id];
          final download = _files.downloadState(message.id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ChatBubble(
              isSent: message.isSent,
              status: message.status,
              burn: message.burn,
              child: FileMessageBody(
                name: file.safeName,
                size: file.size,
                isSent: message.isSent,
                isDirect: file.isDirect,
                localPath: path,
                localMissing: _pathMissing(path),
                downloadDone: download?.done,
                downloadTotal: download?.total,
                downloadError: download?.error,
                onDownload:
                    message.isSent ||
                        path != null ||
                        download != null ||
                        file.isDirect
                    ? null
                    : () => unawaited(_download(message)),
                onCancelDownload: download != null && !download.failed
                    ? () => _files.cancel(download.id)
                    : null,
                onRetry: download != null && download.failed
                    ? () => unawaited(_download(message))
                    : null,
                onDismiss: download != null && download.failed
                    ? () => _files.cancel(download.id)
                    : null,
                onReveal: path != null && !_pathMissing(path)
                    ? () => unawaited(_reveal(path))
                    : null,
                onCopyImage: path != null
                    ? () => unawaited(_copyImage(path))
                    : null,
                onSaveImage: path != null
                    ? () => unawaited(_saveImage(path, file.safeName))
                    : null,
                onOpen: path != null && !_pathMissing(path)
                    ? () => unawaited(_openFile(path))
                    : null,
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ChatBubble(
            text: message.text ?? '（这条消息无法解密）',
            isSent: message.isSent,
            status: message.status,
            burn: message.burn,
          ),
        );
      },
    );
  }
}
