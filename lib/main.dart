import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_services.dart';
import 'ui/main_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite_common_ffi 在桌面端（Linux/Windows）需要先初始化
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  runApp(const WhisperApp());
  // 连接中继放在界面起来之后；失败（例如密钥存储不可用）不应让应用起不来，
  // 各连接自己会重连。
  unawaited(AppServices.instance.start().catchError((Object _) {}));
}
