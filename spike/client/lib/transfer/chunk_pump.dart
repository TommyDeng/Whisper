import 'dart:typed_data';

class ChunkPump {
  ChunkPump({
    required this.sendBinary,
    required this.bufferedAmount,
    required this.waitForDrain,
    this.chunkSize = 16 * 1024,
    this.highWater = 1024 * 1024,
    this.lowWater = 256 * 1024,
    this.drainTimeout = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<void> Function(Uint8List bytes) sendBinary;
  final Future<int> Function() bufferedAmount;
  final Future<void> Function() waitForDrain;
  final int chunkSize;
  final int highWater;
  final int lowWater;
  final Duration drainTimeout;
  final DateTime Function() _now;

  Future<void> send(Stream<List<int>> data, {void Function(Uint8List chunk)? onChunk}) async {
    var queuedSincePoll = 0;
    await for (final raw in data) {
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      var offset = 0;
      while (offset < bytes.length) {
        final end = offset + chunkSize < bytes.length ? offset + chunkSize : bytes.length;
        final slice = Uint8List.sublistView(bytes, offset, end);
        await sendBinary(slice);
        onChunk?.call(slice);
        offset = end;
        queuedSincePoll += slice.length;
        if (queuedSincePoll >= highWater) {
          await _drainUntilLow();
          queuedSincePoll = await bufferedAmount();
        }
      }
    }
    await _drainUntilLow();
  }

  Future<void> _drainUntilLow() async {
    final deadline = _now().add(drainTimeout);
    var amount = await bufferedAmount();
    while (amount > lowWater) {
      if (_now().isAfter(deadline)) {
        throw StateError('数据通道发送缓冲在 ${drainTimeout.inSeconds} 秒内没有降下来');
      }
      await waitForDrain();
      amount = await bufferedAmount();
    }
  }
}
