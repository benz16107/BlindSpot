import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: CameraPreviewScreen(cameras: cameras),
    );
  }
}

class CameraPreviewScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraPreviewScreen({super.key, required this.cameras});

  @override
  State<CameraPreviewScreen> createState() => _CameraPreviewScreenState();
}

class _CameraPreviewScreenState extends State<CameraPreviewScreen> {
  CameraController? _controller;
  bool _initializing = true;
  String _status = "Starting camera…";

  // Location state
  StreamSubscription<Position>? _posSub;
  Position? _pos;
  String? _locError;

  // Haptic feedback state
  Timer? _hapticTimer;
  DateTime? _lastHapticTime;
  bool _justVibrated = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _status = "No cameras found.";
        _initializing = false;
      });
      return;
    }

    final camera = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // good for CV later
    );

    try {
      await controller.initialize();
      setState(() {
        _controller = controller;
        _initializing = false;
        _status = "Camera ready. Getting GPS…";
      });

      // Start location after camera is ready (so UI feels responsive)
      await _startLocation();
    } on CameraException catch (e) {
      setState(() {
        _status = "Camera error: ${e.code} ${e.description}";
        _initializing = false;
      });
    }
  }

  Future<void> _startLocation() async {
    try {
      // 1) Make sure services are on
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _locError = "Location services are disabled.";
          _status = "Camera ready. Enable location services.";
        });
        return;
      }

      // 2) Permissions
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        setState(() {
          _locError = "Location permission denied.";
          _status = "Camera ready. Location permission denied.";
        });
        return;
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _locError =
              "Location permission denied forever. Enable it in Settings.";
          _status = "Camera ready. Enable location in Settings.";
        });
        return;
      }

      // 3) One-shot position first (fast handoff to routing)
      final first = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      if (!mounted) return;
      setState(() {
        _pos = first;
        _status = "Camera + GPS ready.";
        _locError = null;
      });

      // 4) Continuous updates while camera screen is open
      const settings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3, // meters before emitting an update
      );

      _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (p) {
          if (!mounted) return;
          setState(() => _pos = p);
          _handleHapticFeedback(p);
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _locError = e.toString();
          });
        },
      );

      // Start haptic feedback timer (checks every 3 seconds if moving)
      _startHapticTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locError = e.toString();
        _status = "Camera ready. GPS error.";
      });
    }
  }

  void _startHapticTimer() {
    _hapticTimer?.cancel();
    _hapticTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_pos != null && _pos!.speed > 0.5) {
        _triggerHaptic();
      }
    });
  }

  void _handleHapticFeedback(Position position) {
    // Check if we should vibrate based on rate limiting
    if (position.speed > 0.5) {
      final now = DateTime.now();
      if (_lastHapticTime == null ||
          now.difference(_lastHapticTime!).inSeconds >= 3) {
        _triggerHaptic();
        _lastHapticTime = now;
      }
    }
  }

  Future<void> _triggerHaptic() async {
    try {
      await HapticFeedback.mediumImpact();
      // Visual indicator (flashes for debugging)
      setState(() => _justVibrated = true);
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) setState(() => _justVibrated = false);
      });
    } catch (e) {
      // Silently handle haptic errors
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _hapticTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  String _locationLine() {
    if (_locError != null) return "GPS: $_locError";
    if (_pos == null) return "GPS: acquiring…";
    final p = _pos!;
    final speedMsFormatted = p.speed.toStringAsFixed(2);
    final isMoving = p.speed > 0.5 ? "🚶 Walking" : "⏸ Stopped";
    return "📍 ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}\n"
        "📏 ±${p.accuracy.toStringAsFixed(0)}m  |  ${isMoving} ($speedMsFormatted m/s)";
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      body: SafeArea(
        child: _initializing || controller == null || !controller.value.isInitialized
            ? Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: Text(_status, style: const TextStyle(color: Colors.white)),
              )
            : Stack(
                children: [
                  Positioned.fill(child: CameraPreview(controller)),

                  // Status + GPS overlay
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _justVibrated
                            ? Colors.green.withOpacity(0.7)
                            : Colors.black.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(12),
                        border: _locError != null
                            ? Border.all(color: Colors.red, width: 2)
                            : null,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_locError != null)
                            Text(
                              "⚠ GPS: $_locError",
                              style: const TextStyle(
                                color: Colors.yellow,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            )
                          else
                            Text(
                              _status,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            _locationLine(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
