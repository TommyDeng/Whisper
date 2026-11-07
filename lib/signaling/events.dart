import 'dart:convert';

sealed class ServerEvent {
  const ServerEvent();
}

class WelcomeEvent extends ServerEvent {
  const WelcomeEvent(this.role, this.peerCount);

  final String role;
  final int peerCount;
}

class PeerJoinedEvent extends ServerEvent {
  const PeerJoinedEvent(this.peerCount);

  final int peerCount;
}

class PeerLeftEvent extends ServerEvent {
  const PeerLeftEvent();
}

class PongEvent extends ServerEvent {
  const PongEvent();
}

class ErrorEvent extends ServerEvent {
  const ErrorEvent(this.error);

  final String error;
}

class SignalOfferEvent extends ServerEvent {
  const SignalOfferEvent(this.sdp);

  final String sdp;
}

class SignalAnswerEvent extends ServerEvent {
  const SignalAnswerEvent(this.sdp);

  final String sdp;
}

class SignalCandidateEvent extends ServerEvent {
  const SignalCandidateEvent(this.candidate, this.sdpMid, this.sdpMLineIndex);

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;
}

class SignalByeEvent extends ServerEvent {
  const SignalByeEvent();
}

class IgnoredEvent extends ServerEvent {
  const IgnoredEvent(this.reason);

  final String reason;
}

ServerEvent parseServerEvent(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const IgnoredEvent('invalid-json');
  }
  if (decoded is! Map) return const IgnoredEvent('expected-object');
  final type = decoded['type'];
  if (type == 'welcome') {
    final role = decoded['role'];
    final peerCount = decoded['peerCount'];
    if (role is! String || peerCount is! int) return const IgnoredEvent('bad-welcome');
    return WelcomeEvent(role, peerCount);
  }
  if (type == 'peer-joined') {
    final peerCount = decoded['peerCount'];
    return PeerJoinedEvent(peerCount is int ? peerCount : 2);
  }
  if (type == 'peer-left') return const PeerLeftEvent();
  if (type == 'pong') return const PongEvent();
  if (type == 'error') {
    final error = decoded['error'];
    return ErrorEvent(error is String ? error : 'error');
  }
  if (type == 'signal') {
    final kind = decoded['kind'];
    if (kind == 'offer' && decoded['sdp'] is String) {
      return SignalOfferEvent(decoded['sdp'] as String);
    }
    if (kind == 'answer' && decoded['sdp'] is String) {
      return SignalAnswerEvent(decoded['sdp'] as String);
    }
    if (kind == 'candidate' && decoded['candidate'] is String) {
      final mid = decoded['sdpMid'];
      final index = decoded['sdpMLineIndex'];
      return SignalCandidateEvent(
        decoded['candidate'] as String,
        mid is String ? mid : null,
        index is int ? index : null,
      );
    }
    if (kind == 'bye') return const SignalByeEvent();
  }
  return const IgnoredEvent('unknown');
}
