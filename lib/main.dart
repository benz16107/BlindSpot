import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sesesesese/features/debug/haptics_debug_page.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Navigation Assistant',
      home: const _HomeScreen(),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen();

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  Timer? _longPressTimer;

  void _onLongPressStart() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const HapticsDebugPage()),
      );
    });
  }

  void _onLongPressEnd() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPressStart: (_) => _onLongPressStart(),
          onLongPressEnd: (_) => _onLongPressEnd(),
          onLongPressCancel: _onLongPressEnd,
          child: const Text('Navigation Assistant'),
        ),
      ),
      body: const Center(child: Text('Long-press app title (2s) for Haptics Debug')),
    );
  }
}
