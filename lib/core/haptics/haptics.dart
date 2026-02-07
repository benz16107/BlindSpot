import 'package:vibration/vibration.dart';

/// Tactile language: maps navigation commands to distinct vibration patterns.
/// Fully self-contained; no camera, WebSocket, or UI dependencies.
/// Fails silently if vibration is unsupported.
class Haptics {
  Haptics._();

  /// Returns true if the device can vibrate; false otherwise (never throws).
  static Future<bool> isSupported() async {
    try {
      return await Vibration.hasVibrator() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Left turn: short–gap–short pattern (two quick pulses with a brief pause).
  /// Pattern: vibrate 100ms, pause 50ms, vibrate 100ms.
  static Future<void> leftTurn() async {
    if (!await isSupported()) return;
    try {
      await Vibration.vibrate(pattern: [0, 100, 50, 100]);
    } catch (_) {}
  }

  /// Right turn: single steady pulse (500ms).
  static Future<void> rightTurn() async {
    if (!await isSupported()) return;
    try {
      await Vibration.vibrate(duration: 500);
    } catch (_) {}
  }

  /// Danger/stop: urgent triple pulse then long hold (attention-grabbing).
  /// Pattern: 200ms, pause 100ms, 200ms, pause 100ms, 500ms long.
  static Future<void> dangerStop() async {
    if (!await isSupported()) return;
    try {
      await Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 500]);
    } catch (_) {}
  }

  /// Stops any ongoing vibration immediately.
  static Future<void> cancel() async {
    try {
      await Vibration.cancel();
    } catch (_) {}
  }
}
