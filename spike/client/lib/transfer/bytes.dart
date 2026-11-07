import 'dart:typed_data';

Stream<List<int>> xorshiftBytes(int total, {int seed = 0xC0FFEE}) async* {
  if (total < 0) {
    throw ArgumentError.value(total, 'total');
  }
  var state = seed & 0xFFFFFFFF;
  var left = total;
  const block = 16 * 1024;
  while (left > 0) {
    final n = left < block ? left : block;
    final buf = Uint8List(n);
    for (var i = 0; i < n; i++) {
      state ^= (state << 13) & 0xFFFFFFFF;
      state ^= state >> 17;
      state ^= (state << 5) & 0xFFFFFFFF;
      state &= 0xFFFFFFFF;
      buf[i] = state & 0xFF;
    }
    yield buf;
    left -= n;
  }
}
