import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/files/image_file.dart';
import 'package:whisper/files/image_store.dart';

void main() {
  late Directory root;
  late ChatImageStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('whisper_image_store_');
    store = ChatImageStore(root: () async => root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('图片扩展名：小写、不带点，非图片为 null', () {
    expect(imageExtension('a.PNG'), 'png');
    expect(imageExtension('dir.d/b.jpeg'), 'jpeg');
    expect(imageExtension('notes.txt'), isNull);
    expect(imageExtension('noext'), isNull);
  });

  test('目录在数据目录下，重复取是同一个', () async {
    final dir = await store.directory();
    expect(dir.parent.path, root.path);
    expect(await dir.exists(), isTrue);
    expect((await store.directory()).path, dir.path);
  });

  test('prune 只删超过保留期的图片', () async {
    final dir = await store.directory();
    final old = File('${dir.path}/old.png')..writeAsBytesSync([1]);
    final fresh = File('${dir.path}/fresh.png')..writeAsBytesSync([2]);
    final now = DateTime.now();
    old.setLastModifiedSync(now.subtract(const Duration(days: 8)));
    fresh.setLastModifiedSync(now.subtract(const Duration(days: 6)));
    await store.prune(now: now);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('clear 删掉全部图片', () async {
    final dir = await store.directory();
    File('${dir.path}/a.png').writeAsBytesSync([1]);
    await store.clear();
    expect(dir.existsSync(), isFalse);
  });
}
