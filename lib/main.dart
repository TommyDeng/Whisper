import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'ui/main_app.dart';

void main() {
  // sqflite_common_ffi 在桌面端（Linux/Windows）需要先初始化
  databaseFactory = databaseFactoryFfi;
  runApp(const WhisperApp());
}
