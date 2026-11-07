import 'dart:async';

import 'package:flutter/material.dart';

import 'session/call_controller.dart';
import 'ui/spike_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = CallController();
  unawaited(controller.refreshNics());
  runApp(WhisperSpikeApp(controller: controller));
}

class WhisperSpikeApp extends StatefulWidget {
  const WhisperSpikeApp({super.key, this.controller});

  final CallController? controller;

  @override
  State<WhisperSpikeApp> createState() => _WhisperSpikeAppState();
}

class _WhisperSpikeAppState extends State<WhisperSpikeApp> {
  late final CallController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? CallController();
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '耳语 WebRTC Spike',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F3A2E)),
        useMaterial3: true,
      ),
      home: SpikePage(controller: _controller),
    );
  }
}
