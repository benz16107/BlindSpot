import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'config.dart';
import 'voice_service.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:image/image.dart' as img;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (e) {
    // Camera plugin not implemented on this platform (e.g. macOS desktop)
    cameras = [];
  }
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
  // Compass: 0 = north, 90 = east, 180 = south, 270 = west
  double? _heading;
  StreamSubscription<CompassEvent>? _compassSub;

  // Voice agent: on when button pressed, off when pressed again; memory kept on server
  final VoiceService _voiceService = VoiceService();
  bool _voiceConnecting = false;
  String? _voiceError;

  // Mic level indicator: test when not connected to voice (record package)
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _micTesting = false;
  double? _micLevel; // 0..1 normalized from dBFS
  StreamSubscription<Amplitude>? _micLevelSub;

  // Obstacle detection: periodic frame upload, TTS + constant haptic when obstacle near
  bool _obstacleDetectionOn = false;
  Timer? _obstacleTimer;
  Timer? _obstacleHapticTimer; // repeating haptic while obstacle near
  bool _obstacleNear = false;
  String? _obstacleDescription;
  DateTime? _lastObstacleAnnounceTime; // TTS cooldown
  final FlutterTts _tts = FlutterTts();
  GenerativeModel? _obstacleModel; // cached for speed

  @override
  void initState() {
    super.initState();
    _voiceService.addListener(_onVoiceStateChanged);
    _start();
  }

  Future<void> _onVoiceButtonPressed() async {
    HapticFeedback.selectionClick();
    if (_voiceConnecting) return;
    setState(() {
      _voiceError = null;
      _voiceConnecting = true;
    });
    try {
      if (_voiceService.isConnected) {
        await _voiceService.disconnect();
      } else {
        await _voiceService.connect();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _voiceError = e.toString();
          _voiceConnecting = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() => _voiceConnecting = false);
      _announceToScreenReader(
        _voiceService.isConnected
            ? 'Voice agent connected. Say where you want to go or ask where you are.'
            : 'Voice agent disconnected.',
      );
    }
  }

  Future<void> _start() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _status = "No camera (e.g. macOS). GPS + voice only.";
        _initializing = false;
      });
      await _startLocation();
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
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();
      setState(() {
        _controller = controller;
        _initializing = false;
        _status = "Camera ready. Getting GPS…";
      });

      // Obstacle detection starts only when user toggles it on (see FAB)

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
      _voiceService.updateGps(first.latitude, first.longitude, _heading);

      // 4) Compass updates (heading 0–360)
      _compassSub?.cancel();
      _compassSub = FlutterCompass.events?.listen((CompassEvent e) {
        if (!mounted) return;
        if (e.heading != null) setState(() => _heading = e.heading);
      });

      // 5) Continuous position updates while camera screen is open
      const settings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 3, // meters before emitting an update
      );

      _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (p) {
          if (!mounted) return;
          setState(() => _pos = p);
          _voiceService.updateGps(p.latitude, p.longitude, _heading);
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _locError = e.toString();
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locError = e.toString();
        _status = "Camera ready. GPS error.";
      });
    }
  }

  void _onVoiceStateChanged() {
    if (!mounted) return;
    if (!_voiceService.isConnected && _obstacleDetectionOn) {
      _stopObstacleDetection();
      setState(() => _obstacleDetectionOn = false);
    }
    setState(() {});
  }

  /// Obstacle endpoint: same host as token URL from config (only used when not using local Gemini).
  String get _obstacleFrameUrl {
    final u = Uri.parse(tokenUrl.trim().isEmpty ? 'http://localhost:8765/token' : tokenUrl);
    return u.resolve('/obstacle-frame').toString();
  }

  void _startObstacleDetection() {
    _obstacleTimer?.cancel();
    final interval = Duration(milliseconds: obstacleCheckIntervalMs);
    _obstacleTimer = Timer.periodic(interval, (_) => _runObstacleCheck());
    _runObstacleCheck(); // run first check immediately
  }

  void _stopObstacleDetection() {
    _obstacleTimer?.cancel();
    _obstacleTimer = null;
    _stopObstacleAlerts();
    if (mounted) {
      setState(() {
        _obstacleNear = false;
        _obstacleDescription = null;
      });
    }
  }

  /// Constant haptic vibration while obstacle is detected.
  void _startObstacleAlerts(String description) {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = Timer.periodic(Duration(milliseconds: obstacleHapticPeriodMs), (_) {
      if (!_obstacleNear || !mounted) {
        _stopObstacleAlerts();
        return;
      }
      HapticFeedback.heavyImpact();
    });
  }

  void _stopObstacleAlerts() {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = null;
    _tts.stop();
  }

  Future<void> _announceObstacle(String description) async {
    _lastObstacleAnnounceTime = DateTime.now();
    final phrase = description.toLowerCase() == 'object' || description.isEmpty
        ? 'Obstacle detected. Object in front.'
        : 'Obstacle detected. $description in front.';
    await _tts.speak(phrase);
  }

  void _onObstacleDetectionToggle() {
    HapticFeedback.selectionClick();
    if (_obstacleDetectionOn) {
      setState(() => _obstacleDetectionOn = false);
      _stopObstacleDetection();
      _announceToScreenReader('Object detection turned off.');
    } else {
      if (!_voiceService.isConnected) return;
      setState(() => _obstacleDetectionOn = true);
      _startObstacleDetection();
      _announceToScreenReader('Object detection turned on. You will feel vibrations and hear alerts when something is in front.');
    }
  }

  void _announceToScreenReader(String message) {
    try {
      SemanticsService.announce(message, TextDirection.ltr);
    } catch (_) {
      // Announce not supported on this platform
    }
  }

  Future<void> _runObstacleCheck() async {
    if (!_obstacleDetectionOn) return;
    final controller = _controller;
    if (!mounted || controller == null || !controller.value.isInitialized) return;

    try {
      final xfile = await controller.takePicture();
      List<int> bytes = await xfile.readAsBytes();
      if (!mounted || bytes.isEmpty) return;

      bytes = _resizeObstacleImage(bytes);

      Map<String, dynamic>? body;
      if (useLocalObstacleDetection && googleApiKey.trim().isNotEmpty) {
        body = await _analyzeObstacleLocal(bytes);
      } else {
        final url = _obstacleFrameUrl;
        if (url.isEmpty) return;
        final response = await http
            .post(
              Uri.parse(url),
              body: bytes,
              headers: {'Content-Type': 'image/jpeg'},
            )
            .timeout(Duration(seconds: obstacleRequestTimeoutSeconds));
        if (!mounted) return;
        if (response.statusCode != 200) {
          setState(() {
            _obstacleNear = false;
            _obstacleDescription = null;
          });
          return;
        }
        body = jsonDecode(response.body) as Map<String, dynamic>?;
      }

      if (!mounted || body == null) return;
      if (!_obstacleDetectionOn) return;
      final detected = body['obstacle_detected'] == true;
      final distance = (body['distance'] as String? ?? '').toString().toLowerCase();
      final description = (body['description'] as String? ?? '').toString().trim();
      final isNear = detected && obstacleAlertDistances.contains(distance);

      if (!mounted || !_obstacleDetectionOn) return;
      final wasNear = _obstacleNear;
      setState(() {
        _obstacleNear = isNear;
        _obstacleDescription = isNear ? (description.isNotEmpty ? description : 'obstacle') : null;
      });
      if (!_obstacleDetectionOn) return;
      if (isNear) {
        _startObstacleAlerts(description.isNotEmpty ? description : 'object');
        final desc = description.isNotEmpty ? description : 'object';
        final now = DateTime.now();
        final shouldAnnounce = !wasNear ||
            _lastObstacleAnnounceTime == null ||
            now.difference(_lastObstacleAnnounceTime!) > Duration(seconds: obstacleAnnounceCooldownSeconds);
        if (shouldAnnounce) {
          _lastObstacleAnnounceTime = now;
          if (_voiceService.isConnected) {
            _voiceService.publishObstacleDetected(desc);
          } else {
            _announceObstacle(desc);
          }
        }
      } else {
        _stopObstacleAlerts();
      }
    } catch (_) {
      if (mounted && _obstacleDetectionOn) {
        setState(() {
          _obstacleNear = false;
          _obstacleDescription = null;
        });
      }
    }
  }

  /// Resize JPEG for fast upload and inference.
  List<int> _resizeObstacleImage(List<int> imageBytes) {
    if (obstacleImageMaxWidth <= 0) return imageBytes;
    try {
      final decoded = img.decodeImage(Uint8List.fromList(imageBytes));
      if (decoded == null || decoded.width <= obstacleImageMaxWidth) return imageBytes;
      final resized = img.copyResize(decoded, width: obstacleImageMaxWidth);
      final encoded = img.encodeJpg(resized, quality: obstacleJpegQuality);
      return encoded;
    } catch (_) {
      return imageBytes;
    }
  }

  /// Call Gemini API directly from the app (no obstacle server). Model cached for speed.
  Future<Map<String, dynamic>?> _analyzeObstacleLocal(List<int> imageBytes) async {
    try {
      _obstacleModel ??= GenerativeModel(
        model: obstacleModel,
        apiKey: googleApiKey.trim(),
        generationConfig: GenerationConfig(
          responseMimeType: 'application/json',
          temperature: obstacleTemperature,
          maxOutputTokens: obstacleMaxOutputTokens,
        ),
      );
      final response = await _obstacleModel!.generateContent([
        Content.multi([
          DataPart('image/jpeg', Uint8List.fromList(imageBytes)),
          TextPart(obstaclePrompt),
        ]),
      ]);
      final text = response.text?.trim() ?? '';
      if (text.isEmpty) return null;
      String jsonStr = text;
      if (text.contains('```')) {
        final start = text.indexOf('{');
        final end = text.lastIndexOf('}') + 1;
        if (start >= 0 && end > start) jsonStr = text.substring(start, end);
      }
      final out = jsonDecode(jsonStr) as Map<String, dynamic>?;
      if (out == null) return null;
      final detected = out['obstacle_detected'];
      bool det;
      if (detected is bool) {
        det = detected;
      } else if (detected is String) {
        det = ['true', '1', 'yes'].contains(detected.toLowerCase());
      } else {
        det = false;
      }
      var dist = (out['distance'] as String? ?? '').toString().toLowerCase();
      if (dist != 'far' && dist != 'medium' && dist != 'near') dist = det ? 'medium' : 'none';
      return {
        'obstacle_detected': det,
        'distance': dist,
        'description': (out['description'] as String? ?? '').toString().trim(),
      };
    } catch (e) {
      debugPrint('_analyzeObstacleLocal: $e');
      return null;
    }
  }

  Future<void> _stopMicTest() async {
    HapticFeedback.selectionClick();
    await _micLevelSub?.cancel();
    _micLevelSub = null;
    try {
      await _audioRecorder.stop();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _micTesting = false;
        _micLevel = null;
      });
    }
  }

  Future<void> _startMicTest() async {
    HapticFeedback.selectionClick();
    if (_voiceService.isConnected || _micTesting) return;
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      if (mounted) {
        setState(() => _voiceError = 'Mic permission denied');
      }
      return;
    }
    String path;
    try {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/mic_test_${DateTime.now().millisecondsSinceEpoch}.m4a';
    } catch (_) {
      path = 'mic_test.m4a';
    }
    try {
      await _audioRecorder.start(const RecordConfig(), path: path);
    } catch (e) {
      if (mounted) setState(() => _voiceError = 'Mic start: $e');
      return;
    }
    setState(() {
      _micTesting = true;
      _micLevel = 0;
      _voiceError = null;
    });
    // dBFS: roughly -60 (quiet) to 0 (loud); normalize to 0..1
    _micLevelSub = _audioRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((Amplitude a) {
      if (!mounted || !_micTesting) return;
      final normalized = (a.current + 60) / 60;
      setState(() => _micLevel = normalized.clamp(0.0, 1.0));
    });
    // Auto-stop after 15 seconds
    Future<void>.delayed(const Duration(seconds: 15), () {
      if (_micTesting) _stopMicTest();
    });
  }

  @override
  void dispose() {
    _obstacleTimer?.cancel();
    _obstacleTimer = null;
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = null;
    _stopMicTest();
    _voiceService.removeListener(_onVoiceStateChanged);
    _voiceService.disconnect();
    _posSub?.cancel();
    _compassSub?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  String _locationLine() {
    if (_locError != null) return "GPS: $_locError";
    if (_pos == null) return "GPS: acquiring…";
    final p = _pos!;
    return "GPS: ${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)} "
        "(±${p.accuracy.toStringAsFixed(0)}m)";
  }

  String _headingLabel(double heading) {
    final deg = heading.round() % 360;
    final dir = deg >= 337.5 || deg < 22.5
        ? 'north'
        : deg >= 22.5 && deg < 67.5
            ? 'north-east'
            : deg >= 67.5 && deg < 112.5
                ? 'east'
                : deg >= 112.5 && deg < 157.5
                    ? 'south-east'
                    : deg >= 157.5 && deg < 202.5
                        ? 'south'
                        : deg >= 202.5 && deg < 247.5
                            ? 'south-west'
                            : deg >= 247.5 && deg < 292.5
                                ? 'west'
                                : 'north-west';
    return 'Facing $dir. $deg degrees.';
  }

  /// Single-sentence summary for screen reader (status card).
  String _statusSummaryForAccessibility() {
    final parts = <String>[_status, _locationLine()];
    if (_obstacleNear && _obstacleDescription != null) {
      parts.add('Obstacle in front: $_obstacleDescription');
    }
    if (_voiceError != null) {
      parts.add('Voice error: $_voiceError');
    } else if (_voiceConnecting) {
      parts.add('Voice: connecting');
    } else if (_voiceService.isConnected) {
      parts.add('Voice agent: on');
    } else {
      parts.add('Voice agent: off');
    }
    parts.add(_obstacleDetectionOn ? 'Object detection: on' : 'Object detection: off');
    return parts.join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    final showCamera = controller != null && controller.value.isInitialized;
    return Scaffold(
      body: SafeArea(
        child: _initializing && controller == null
            ? Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: Text(_status, style: const TextStyle(color: Colors.white)),
              )
            : Stack(
                children: [
                  Positioned.fill(
                    child: showCamera
                        ? ExcludeSemantics(
                            child: _CameraPreviewFullScreen(controller: controller),
                          )
                        : Container(color: Colors.black87, child: Center(child: Text(_status, style: const TextStyle(color: Colors.white54)))),
                  ),

                  // Status + GPS overlay (semantic summary for screen reader)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: Semantics(
                      container: true,
                      label: _statusSummaryForAccessibility(),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_status, style: const TextStyle(color: Colors.white, fontSize: 15)),
                            const SizedBox(height: 6),
                            Text(_locationLine(), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                          if (_obstacleNear && _obstacleDescription != null) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.warning_amber_rounded, color: Colors.orange.shade300, size: 18),
                                const SizedBox(width: 6),
                                Text(
                                  'Obstacle: $_obstacleDescription',
                                  style: TextStyle(color: Colors.orange.shade200, fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ],
                          if (_voiceError != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Voice: $_voiceError',
                              style: const TextStyle(color: Colors.orangeAccent),
                            ),
                          ] else ...[
                            const SizedBox(height: 4),
                            Text(
                              _voiceConnecting
                                  ? 'Voice: connecting…'
                                  : _voiceService.isConnected
                                      ? 'Voice: on'
                                      : 'Voice: off (tap mic to start)',
                              style: const TextStyle(color: Colors.white70),
                            ),
                            // Mic level: test when not connected, or "live" when connected
                            const SizedBox(height: 6),
                            if (_micTesting) ...[
                              Row(
                                children: [
                                  SizedBox(
                                    width: 120,
                                    height: 20,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: _micLevel ?? 0,
                                        backgroundColor: Colors.white24,
                                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Mic: ${((_micLevel ?? 0) * 100).toStringAsFixed(0)}%',
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                  const SizedBox(width: 8),
                                  Semantics(
                                    label: 'Stop mic test',
                                    hint: 'Double tap to stop listening',
                                    button: true,
                                    child: GestureDetector(
                                      onTap: _stopMicTest,
                                      behavior: HitTestBehavior.opaque,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                        constraints: const BoxConstraints(minHeight: 48),
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          color: Colors.orange.shade700,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          'Stop',
                                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Listening… speak to test (stops in 15s or tap Stop)',
                                style: TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                            ] else if (!_voiceService.isConnected && !_voiceConnecting) ...[
                              Semantics(
                                label: 'Test mic level',
                                hint: 'Double tap to test your microphone before connecting',
                                button: true,
                                child: GestureDetector(
                                  onTap: _startMicTest,
                                  behavior: HitTestBehavior.opaque,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    constraints: const BoxConstraints(minHeight: 48),
                                    decoration: BoxDecoration(
                                      color: Colors.white24,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white38),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.mic_none, size: 22, color: Colors.white),
                                        SizedBox(width: 10),
                                        Text('Test mic level', style: TextStyle(color: Colors.white, fontSize: 15)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ] else if (_voiceService.isConnected) ...[
                              Row(
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: const BoxDecoration(
                                      color: Colors.green,
                                      shape: BoxShape.circle,
                                      boxShadow: [BoxShadow(color: Colors.green, blurRadius: 4)],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text('Mic live (sending to agent)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                ],
                              ),
                            ],
                            // Object detection: tap ⚠ FAB to toggle
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 14,
                                  color: _obstacleDetectionOn ? Colors.orange.shade300 : Colors.white54,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _obstacleDetectionOn
                                      ? 'Object detection: on'
                                      : _voiceService.isConnected
                                          ? 'Object detection: off (tap ⚠ to turn on)'
                                          : 'Object detection: connect voice first',
                                  style: TextStyle(
                                    color: _obstacleDetectionOn ? Colors.orange.shade200 : Colors.white54,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                            if (kIsWeb && !_voiceService.isConnected && !_voiceConnecting) ...[
                              const SizedBox(height: 2),
                              Text(
                                'Chrome: allow mic when prompted. After connecting, tap "Tap to enable speaker" if you can\'t hear.',
                                style: TextStyle(color: Colors.white54, fontSize: 11),
                              ),
                            ],
                            // Chrome: show speaker unlock when playback failed OR when on web and connected (tap proactively)
                            if (_voiceService.audioPlaybackFailed || (kIsWeb && _voiceService.isConnected)) ...[
                              if (kIsWeb) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Chrome: allow microphone when prompted. If you can\'t hear the agent, tap below.',
                                  style: TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Semantics(
                                label: _voiceService.audioPlaybackFailed
                                    ? 'Tap to enable speaker. Required in Chrome to hear the agent.'
                                    : 'Tap to enable speaker',
                                hint: 'Double tap to unlock audio playback',
                                button: true,
                                child: GestureDetector(
                                  onTap: () async {
                                    HapticFeedback.selectionClick();
                                    await _voiceService.playbackAudio();
                                  },
                                  behavior: HitTestBehavior.opaque,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                    constraints: const BoxConstraints(minHeight: 48),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade700,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white24),
                                    ),
                                    child: Text(
                                      _voiceService.audioPlaybackFailed
                                          ? 'Tap to enable speaker (Chrome)'
                                          : 'Tap to enable speaker',
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                    ),
                  ),

                  // Compass: direction you're facing (above the bottom button strip)
                  if (_heading != null)
                    Positioned(
                      left: 12,
                      bottom: 130,
                      child: Semantics(
                        label: _headingLabel(_heading!),
                        container: true,
                        child: _CompassWidget(heading: _heading!),
                      ),
                    ),

                  // Primary actions: Voice + Object detection (large, high-contrast, screen-reader friendly)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 16,
                    child: Row(
                      children: [
                        // Object detection (only when voice is on)
                        Expanded(
                          child: Semantics(
                            label: _voiceService.isConnected
                                ? (_obstacleDetectionOn
                                    ? 'Object detection. On. Double tap to turn off.'
                                    : 'Object detection. Off. Double tap to turn on.')
                                : 'Object detection. Connect voice first.',
                            hint: _voiceService.isConnected ? 'Double tap to toggle obstacle alerts' : null,
                            button: true,
                            enabled: _voiceService.isConnected,
                            child: Material(
                              color: _voiceService.isConnected
                                  ? (_obstacleDetectionOn ? Colors.orange.shade700 : Colors.grey.shade800)
                                  : Colors.grey.shade900,
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                onTap: _voiceService.isConnected ? _onObstacleDetectionToggle : null,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                  alignment: Alignment.center,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.warning_amber_rounded,
                                        size: 28,
                                        color: _voiceService.isConnected
                                            ? (_obstacleDetectionOn ? Colors.white : Colors.white70)
                                            : Colors.white38,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        'Obstacles',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: _voiceService.isConnected
                                              ? (_obstacleDetectionOn ? Colors.white : Colors.white70)
                                              : Colors.white38,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Voice agent toggle
                        Expanded(
                          child: Semantics(
                            label: _voiceConnecting
                                ? 'Voice agent. Connecting.'
                                : (_voiceService.isConnected
                                    ? 'Voice agent. On. Double tap to disconnect.'
                                    : 'Voice agent. Off. Double tap to connect.'),
                            hint: _voiceConnecting ? null : 'Double tap to turn voice assistant on or off',
                            button: true,
                            enabled: !_voiceConnecting,
                            child: Material(
                              color: _voiceConnecting
                                  ? Colors.grey.shade700
                                  : (_voiceService.isConnected ? Colors.green.shade700 : Colors.grey.shade800),
                              borderRadius: BorderRadius.circular(12),
                              child: InkWell(
                                onTap: _voiceConnecting ? null : _onVoiceButtonPressed,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                  alignment: Alignment.center,
                                  child: _voiceConnecting
                                      ? const SizedBox(
                                          width: 28,
                                          height: 28,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 3,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Row(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.mic,
                                              size: 28,
                                              color: _voiceService.isConnected ? Colors.white : Colors.white70,
                                            ),
                                            const SizedBox(width: 10),
                                            Text(
                                              'Voice',
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w600,
                                                color: _voiceService.isConnected ? Colors.white : Colors.white70,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Full-screen camera preview at native aspect ratio (covers screen, no stretch).
class _CameraPreviewFullScreen extends StatelessWidget {
  final CameraController controller;

  const _CameraPreviewFullScreen({required this.controller});

  @override
  Widget build(BuildContext context) {
    final ar = controller.value.aspectRatio;
    if (ar <= 0) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        // Size (w, h) with w/h = ar that covers maxW x maxH
        final h = maxH > maxW / ar ? maxH : maxW / ar;
        final w = ar * h;
        return Container(
          color: Colors.black,
          child: ClipRect(
            child: Center(
              child: SizedBox(
                width: w,
                height: h,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Compass showing current heading: N at top, needle points in direction of travel.
class _CompassWidget extends StatelessWidget {
  final double heading; // 0 = north, 90 = east (degrees)

  const _CompassWidget({required this.heading});

  @override
  Widget build(BuildContext context) {
    const double size = 56;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withOpacity(0.6),
        border: Border.all(color: Colors.white38, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 8, spreadRadius: 1),
        ],
      ),
      child: ClipOval(
        child: CustomPaint(
          size: const Size(size, size),
          painter: _CompassPainter(heading: heading),
        ),
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double heading;

  _CompassPainter({required this.heading});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Cardinal labels (N at top; compass is fixed, needle rotates)
    final textPainter = (String label, double angleDeg) {
      final rad = (angleDeg - 90) * math.pi / 180;
      final pos = center + Offset(radius * 0.75 * math.cos(rad), radius * 0.75 * math.sin(rad));
      final p = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, pos - Offset(p.width / 2, p.height / 2));
    };
    textPainter('N', 0);
    textPainter('E', 90);
    textPainter('S', 180);
    textPainter('W', 270);

    // Needle: direction you're facing (rotates with heading)
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(heading * math.pi / 180);
    canvas.translate(-center.dx, -center.dy);
    final needlePath = Path()
      ..moveTo(center.dx, center.dy - radius * 0.5)
      ..lineTo(center.dx - 6, center.dy + radius * 0.35)
      ..lineTo(center.dx, center.dy + radius * 0.2)
      ..lineTo(center.dx + 6, center.dy + radius * 0.35)
      ..close();
    canvas.drawPath(needlePath, Paint()..color = Colors.orange..style = PaintingStyle.fill);
    canvas.drawPath(needlePath, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) => old.heading != heading;
}
