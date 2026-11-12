import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/call/call_service.dart';
import 'package:whisper/call/call_sound.dart';
import 'package:whisper/call/message_sound.dart';

class _FakePlayer implements CallSoundPlayer {
  final List<String> log = [];

  @override
  Future<void> loop(String asset) async => log.add('loop:$asset');

  @override
  Future<void> playOnce(String asset) async => log.add('once:$asset');

  @override
  Future<void> stop() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');
}

void main() {
  const session = 'session-1';

  test('自己发出的不响；对方发来的默认要响', () {
    expect(
      shouldPlayMessageSound(
        fromSelf: true,
        sessionId: session,
        visibleSessionId: null,
        windowFocused: false,
        callPhase: CallPhase.idle,
      ),
      isFalse,
    );
    expect(
      shouldPlayMessageSound(
        fromSelf: false,
        sessionId: session,
        visibleSessionId: null,
        windowFocused: true,
        callPhase: CallPhase.idle,
      ),
      isTrue,
    );
  });

  test('通话进行中或刚结束时不响', () {
    for (final phase in [
      CallPhase.incoming,
      CallPhase.outgoing,
      CallPhase.connecting,
      CallPhase.active,
      CallPhase.ended,
    ]) {
      expect(
        shouldPlayMessageSound(
          fromSelf: false,
          sessionId: session,
          visibleSessionId: null,
          windowFocused: false,
          callPhase: phase,
        ),
        isFalse,
        reason: '$phase 时不应响',
      );
    }
  });

  test('窗口在前台且正看着该会话时不响；切到别的会话或窗口不在前台时要响', () {
    expect(
      shouldPlayMessageSound(
        fromSelf: false,
        sessionId: session,
        visibleSessionId: session,
        windowFocused: true,
        callPhase: CallPhase.idle,
      ),
      isFalse,
    );
    expect(
      shouldPlayMessageSound(
        fromSelf: false,
        sessionId: session,
        visibleSessionId: 'other',
        windowFocused: true,
        callPhase: CallPhase.idle,
      ),
      isTrue,
    );
    expect(
      shouldPlayMessageSound(
        fromSelf: false,
        sessionId: session,
        visibleSessionId: session,
        windowFocused: false,
        callPhase: CallPhase.idle,
      ),
      isTrue,
    );
  });

  test('chime 播放一次来信提示音', () async {
    final player = _FakePlayer();
    final sound = MessageSound(player: player);
    await sound.chime();
    await sound.chime();
    await sound.dispose();
    expect(player.log, [
      'once:$kMessageChimeAsset',
      'once:$kMessageChimeAsset',
      'dispose',
    ]);
  });
}
