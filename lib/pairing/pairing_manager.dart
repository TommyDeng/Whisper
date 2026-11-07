/// 配对管理器：处理邀请码生成、解析、配对请求、手动批准。
///
/// 配对状态机：
///   idle -> generating (生成邀请码) -> waiting (等待对方加入)
///   idle -> entering (输入邀请码) -> requesting (发送配对请求)
///   waiting/requesting -> approving (等待邀请人批准) -> approved (会话建立)
///   任何阶段 -> failed (失败)

import 'dart:async';
import 'dart:convert';

import '../identity/identity.dart';
import 'invitation_code.dart';

/// 配对状态。
enum PairingState {
  idle,
  generating,
  waiting,
  entering,
  requesting,
  approving,
  approved,
  failed,
}

/// 配对请求（信令传输）。
class PairingRequest {
  const PairingRequest({
    required this.requestId,
    required this.inviterPublicKey,
    required this.inviteePublicKey,
    required this.timestamp,
  });

  final String requestId;
  final String inviterPublicKey;
  final String? inviteePublicKey; // null 表示对方尚未发送自己的公钥
  final int timestamp;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'inviterPublicKey': inviterPublicKey,
    if (inviteePublicKey != null) 'inviteePublicKey': inviteePublicKey,
    'timestamp': timestamp,
  };

  static PairingRequest fromJson(Map<String, dynamic> json) => PairingRequest(
    requestId: json['requestId'] as String,
    inviterPublicKey: json['inviterPublicKey'] as String,
    inviteePublicKey: json['inviteePublicKey'] as String?,
    timestamp: json['timestamp'] as int,
  );
}

/// 配对结果。
class PairingResult {
  const PairingResult({
    required this.success,
    required this.sessionId,
    required this.peerPublicKey,
    required this.safetyCode,
    this.error,
  });

  final bool success;
  final String sessionId;
  final String peerPublicKey;
  final String safetyCode;
  final String? error;
}

/// 配对管理器。
class PairingManager {
  PairingManager({required this.identityManager});

  final IdentityManager identityManager;

  PairingState _state = PairingState.idle;
  String? _sessionId;
  String? _peerPublicKey;
  String? _safetyCode;
  String? _error;
  InvitationCode? _myInvitation;
  PairingRequest? _incomingRequest;

  StreamController<PairingState>? _stateController;
  StreamController<PairingRequest?>? _requestController;

  PairingState get state => _state;
  String? get sessionId => _sessionId;
  String? get peerPublicKey => _peerPublicKey;
  String? get safetyCode => _safetyCode;
  String? get error => _error;
  InvitationCode? get myInvitation => _myInvitation;
  PairingRequest? get incomingRequest => _incomingRequest;

  Stream<PairingState> get stateStream {
    _stateController ??= StreamController<PairingState>.broadcast();
    return _stateController!.stream;
  }

  Stream<PairingRequest?> get requestStream {
    _requestController ??= StreamController<PairingRequest?>.broadcast();
    return _requestController!.stream;
  }

  /// 生成邀请码（作为邀请方）。
  Future<InvitationCode> generateInvitation() async {
    _setState(PairingState.generating);
    final identity = await identityManager.identity;
    _myInvitation = InvitationCode.create(identity.x25519PublicKey);
    _setState(PairingState.waiting);
    return _myInvitation!;
  }

  /// 解析并使用邀请码（作为被邀请方）。
  Future<PairingResult> useInvitation(String code, {String? sessionId}) async {
    _setState(PairingState.entering);
    final invitation = InvitationCode.decode(code);
    if (invitation == null) {
      _setError('邀请码格式无效');
      return const PairingResult(
        success: false,
        sessionId: '',
        peerPublicKey: '',
        safetyCode: '',
        error: '邀请码格式无效',
      );
    }
    if (invitation.isExpired) {
      _setError('邀请码已过期');
      return const PairingResult(
        success: false,
        sessionId: '',
        peerPublicKey: '',
        safetyCode: '',
        error: '邀请码已过期',
      );
    }

    final identity = await identityManager.identity;
    _incomingRequest = PairingRequest(
      requestId: invitation.requestId,
      inviterPublicKey: base64Url.encode(invitation.publicKey),
      inviteePublicKey: identity.x25519PublicKeyBase64,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _setState(PairingState.requesting);

    // 这里应通过信令发送配对请求，实际实现需整合 WebSocket
    // 暂时模拟：等待邀请人批准
    _setState(PairingState.approving);

    return const PairingResult(
      success: true,
      sessionId: '',
      peerPublicKey: '',
      safetyCode: '',
    );
  }

  /// 邀请方批准配对请求。
  Future<bool> approveRequest(String requestId) async {
    if (_incomingRequest?.requestId != requestId) {
      return false;
    }
    _setState(PairingState.approved);
    return true;
  }

  /// 拒绝配对请求。
  Future<void> rejectRequest(String requestId) async {
    if (_incomingRequest?.requestId != requestId) return;
    _setState(PairingState.idle);
    _incomingRequest = null;
  }

  /// 取消配对。
  Future<void> cancel() async {
    _setState(PairingState.idle);
    _myInvitation = null;
    _incomingRequest = null;
    _sessionId = null;
    _peerPublicKey = null;
    _safetyCode = null;
    _error = null;
  }

  void _setState(PairingState state) {
    _state = state;
    _stateController?.add(state);
  }

  void _setError(String message) {
    _error = message;
    _setState(PairingState.failed);
  }

  void dispose() {
    _stateController?.close();
    _requestController?.close();
  }
}
