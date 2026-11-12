/// 应用级服务：身份、消息、配对、通话、文件。界面通过 [AppServices.instance] 取用。
///
/// 构造时不做任何 I/O；网络连接只在 [start]（由 main 调用）之后才建立，
/// 所以 widget 测试里可以直接构造界面。
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'app_config.dart';
import 'call/call_service.dart';
import 'call/call_transport.dart';
import 'call/webrtc_call_media.dart';
import 'contact/contact.dart';
import 'files/file_direct_link.dart';
import 'files/file_direct_service.dart';
import 'files/file_direct_transport.dart';
import 'files/file_relay_api.dart';
import 'files/file_relay_transfer.dart';
import 'files/file_share_service.dart';
import 'identity/identity_store.dart';
import 'messaging/messaging_service.dart';
import 'pairing/pairing_manager.dart';
import 'relay/ws_connector.dart';
import 'session/rtc_config.dart';
import 'storage/app_database.dart';
import 'storage/settings_store.dart';
import 'ui/ui_focus.dart';
import 'voice/ice_strategy.dart';

class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  late final IdentityManager identityManager = IdentityManager(
    store: IdentityStore(profile: AppConfig.profile),
  );

  late final MessagingService messaging = MessagingService(
    baseUri: AppConfig.relayUri,
    connector: connectWebSocket,
    identity: () => identityManager.identity,
  );

  late final PairingManager pairing = PairingManager(
    baseUri: AppConfig.relayUri,
    connector: connectWebSocket,
    identityManager: identityManager,
    myName: () async =>
        await SettingsStore.get(SettingsStore.displayName) ?? '',
    onContact: _onContact,
  );

  /// 当前窗口和打开的会话，供来信提示音使用。
  final uiFocus = UiFocus();

  /// 文件：双方在线时走 WebRTC 数据通道直传；离线或直连失败且用户确认后走中转。
  late final FileShareService files = FileShareService(
    messaging: messaging,
    transfer: FileRelayTransfer(HttpFileRelay(AppConfig.relayUri)),
    direct: FileDirectService(
      transport: MessagingFileDirectTransport(messaging),
      createLink: () => WebRtcFileLink(),
    ),
  );

  /// 语音通话。信令走 [messaging] 的加密临时消息，音频走 WebRTC。
  late final CallService calls = CallService(
    transport: MessagingCallTransport(messaging),
    createMedia: _createCallMedia,
  );

  final _callPaths = StreamController<IcePathType?>.broadcast();
  StreamSubscription<IcePathType>? _callPathSubscription;
  final _callMicLevels = StreamController<double>.broadcast();
  StreamSubscription<double>? _callMicLevelSubscription;
  final _callRenderers = StreamController<RTCVideoRenderer?>.broadcast();
  StreamSubscription<RTCVideoRenderer?>? _callRendererSubscription;

  /// 当前通话走的路径（局域网 / ZeroTier / 公网直连 / 中继）；新通话开始时先发一个 null。
  Stream<IcePathType?> get callPaths => _callPaths.stream;

  /// 当前通话的本端麦克风电平（0.0–1.0）；新通话开始时先发 0。
  Stream<double> get callMicLevels => _callMicLevels.stream;

  /// 用于播放远端音频的隐藏渲染器；新通话开始或结束时发 null。
  Stream<RTCVideoRenderer?> get callRemoteRenderers => _callRenderers.stream;

  CallMedia _createCallMedia(Contact contact) {
    final media = WebRtcCallMedia(
      loadConfig: () => buildPeerConnectionConfig(
        signalingUrl: AppConfig.relayUri.toString(),
        forceRelay: AppConfig.forceRelay,
        sessionId: contact.sessionId,
        peer: contact.peerRole,
      ),
    );
    unawaited(_callPathSubscription?.cancel());
    unawaited(_callMicLevelSubscription?.cancel());
    unawaited(_callRendererSubscription?.cancel());
    _callPaths.add(null);
    _callMicLevels.add(0);
    _callRenderers.add(null);
    _callPathSubscription = media.paths.listen(_callPaths.add);
    _callMicLevelSubscription = media.localAudioLevels.listen(_callMicLevels.add);
    _callRendererSubscription = media.remoteRendererChanges.listen(_callRenderers.add);
    return media;
  }

  Future<void>? _starting;
  Timer? _retentionTimer;

  /// 连接中继：恢复已有会话和没走完的配对。重复调用无效果。
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    await _applyRetention();
    _retentionTimer ??= Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(_applyRetention()),
    );
    calls; // 开始监听来电
    files; // 开始监听大文件直传
    await messaging.start();
    await pairing.start();
  }

  /// 本地保留策略：超过 7 天的消息删除；上次没来得及清的已读焚毁消息删除。
  Future<void> _applyRetention() async {
    try {
      await messaging.purgeExpired();
      await messaging.purgeBurned();
    } catch (_) {
      // 这次没清成，下个小时再试
    }
  }

  Future<void> _onContact(Contact contact) async {
    // 与同一个人重新配对会换一个会话：旧连接不再需要，旧聊天记录搬到新会话下
    final previous = await ContactStore.getContact(contact.deviceId);
    var saved = contact;
    if (previous != null && previous.sessionId != contact.sessionId) {
      await messaging.detach(previous);
      await messaging.adopt(previous, contact);
      saved = contact.copyWith(burnAfterRead: previous.burnAfterRead);
    }
    await ContactStore.upsertContact(saved);
    await messaging.attach(saved);
  }

  /// 删除联系人及其本地消息。
  Future<void> removeContact(Contact contact) async {
    files.cancelSession(contact.sessionId);
    await messaging.forget(contact);
    await ContactStore.deleteContact(contact.deviceId);
  }

  /// 清除本机的全部数据：聊天记录、联系人、邀请、设置、数据库密钥和自己的身份。
  /// 之后应用回到第一次启动时的状态（会生成一个新身份）。对方设备上的数据不受影响。
  Future<void> clearAllData() async {
    _retentionTimer?.cancel();
    _retentionTimer = null;
    await calls.hangup();
    await calls.decline();
    calls.dismiss();
    await pairing.reset();
    files.reset();
    await messaging.reset();
    await AppDatabase.destroy();
    await identityManager.reset();
    _starting = null;
    await start();
  }
}
