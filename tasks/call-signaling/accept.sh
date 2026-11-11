#!/usr/bin/env bash
set -euo pipefail
flutter test --no-pub -r failures-only test/call test/messaging
# 状态机不能直接依赖 WebRTC、网络或数据库
! grep -nE "flutter_webrtc|dart:io|storage/|relay/" lib/call/call_service.dart
# 不许留占位
! grep -n "UnimplementedError" lib/call/call_service.dart lib/messaging/messaging_service.dart
test -s docs/call-signaling.md
