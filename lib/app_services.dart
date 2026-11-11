/// 应用级服务：身份、消息、配对。界面通过 [AppServices.instance] 取用。
///
/// 构造时不做任何 I/O；网络连接只在 [start]（由 main 调用）之后才建立，
/// 所以 widget 测试里可以直接构造界面。
library;

import 'dart:async';

import 'app_config.dart';
import 'contact/contact.dart';
import 'identity/identity_store.dart';
import 'messaging/messaging_service.dart';
import 'pairing/pairing_manager.dart';
import 'relay/ws_connector.dart';
import 'storage/app_database.dart';
import 'storage/settings_store.dart';

class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  late final IdentityManager identityManager =
      IdentityManager(store: IdentityStore(profile: AppConfig.profile));

  late final MessagingService messaging = MessagingService(
    baseUri: AppConfig.relayUri,
    connector: connectWebSocket,
    identity: () => identityManager.identity,
  );

  late final PairingManager pairing = PairingManager(
    baseUri: AppConfig.relayUri,
    connector: connectWebSocket,
    identityManager: identityManager,
    myName: () async => await SettingsStore.get(SettingsStore.displayName) ?? '',
    onContact: _onContact,
  );

  Future<void>? _starting;
  Timer? _retentionTimer;

  /// 连接中继：恢复已有会话和没走完的配对。重复调用无效果。
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    await _applyRetention();
    _retentionTimer ??= Timer.periodic(const Duration(hours: 1), (_) => unawaited(_applyRetention()));
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
    await messaging.forget(contact);
    await ContactStore.deleteContact(contact.deviceId);
  }

  /// 清除本机的全部数据：聊天记录、联系人、邀请、设置、数据库密钥和自己的身份。
  /// 之后应用回到第一次启动时的状态（会生成一个新身份）。对方设备上的数据不受影响。
  Future<void> clearAllData() async {
    _retentionTimer?.cancel();
    _retentionTimer = null;
    await pairing.reset();
    await messaging.reset();
    await AppDatabase.destroy();
    await identityManager.reset();
    _starting = null;
    await start();
  }
}
