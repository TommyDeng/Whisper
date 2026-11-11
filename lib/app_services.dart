/// 应用级服务：身份、消息、配对。界面通过 [AppServices.instance] 取用。
///
/// 构造时不做任何 I/O；网络连接只在 [start]（由 main 调用）之后才建立，
/// 所以 widget 测试里可以直接构造界面。
library;

import 'app_config.dart';
import 'contact/contact.dart';
import 'identity/identity_store.dart';
import 'messaging/messaging_service.dart';
import 'pairing/pairing_manager.dart';
import 'relay/ws_connector.dart';
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

  /// 连接中继：恢复已有会话和没走完的配对。重复调用无效果。
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    await messaging.start();
    await pairing.start();
  }

  Future<void> _onContact(Contact contact) async {
    // 与同一个人重新配对会换一个会话；旧会话的连接不再需要
    final previous = await ContactStore.getContact(contact.deviceId);
    if (previous != null && previous.sessionId != contact.sessionId) {
      await messaging.detach(previous);
    }
    await ContactStore.upsertContact(contact);
    await messaging.attach(contact);
  }

  /// 删除联系人及其本地消息。
  Future<void> removeContact(Contact contact) async {
    await messaging.forget(contact);
    await ContactStore.deleteContact(contact.deviceId);
  }
}
