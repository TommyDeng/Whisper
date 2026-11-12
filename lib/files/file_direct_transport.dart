/// 把 [MessagingService] 的加密临时消息通道接给 [FileDirectService]。
library;

import '../contact/contact.dart';
import '../messaging/messaging_service.dart';
import 'file_direct_service.dart';

class MessagingFileDirectTransport implements FileDirectTransport {
  MessagingFileDirectTransport(this._messaging);

  final MessagingService _messaging;

  @override
  Future<String?> send(Contact contact, String body) =>
      _messaging.sendFileSignal(contact, body);

  @override
  Stream<IncomingFileSignal> get incoming => _messaging.fileSignals.map(
    (signal) => IncomingFileSignal(signal.contact, signal.body),
  );

  @override
  Stream<({String sessionId, String id})> get dropped =>
      _messaging.signalDropped;
}
