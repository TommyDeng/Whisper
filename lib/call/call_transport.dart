/// 把 [MessagingService] 的加密临时消息通道接给 [CallService]。
library;

import '../contact/contact.dart';
import '../messaging/messaging_service.dart';
import 'call_service.dart';

class MessagingCallTransport implements CallTransport {
  MessagingCallTransport(this._messaging);

  final MessagingService _messaging;

  @override
  Future<String?> send(Contact contact, String body) => _messaging.sendCallSignal(contact, body);

  @override
  Stream<IncomingCallSignal> get incoming =>
      _messaging.callSignals.map((signal) => IncomingCallSignal(signal.contact, signal.body));

  @override
  Stream<({String sessionId, String id})> get dropped => _messaging.signalDropped;
}
