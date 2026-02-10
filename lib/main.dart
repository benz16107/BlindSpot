import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
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
  // Edge-to-edge: draw behind status bar and nav bar so camera fills the screen
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));
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
      home: SplashScreen(cameras: cameras),
    );
  }
}

/// Splash screen: shows for 3 seconds then navigates to HomeScreen.
class SplashScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const SplashScreen({super.key, required this.cameras});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => HomeScreen(cameras: widget.cameras),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        color: Colors.white,
        alignment: Alignment.center,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortest = constraints.maxWidth < constraints.maxHeight
                ? constraints.maxWidth
                : constraints.maxHeight;
            final size = shortest * 0.9;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/splash.png',
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 12),
                const Text('Launching...', style: TextStyle(fontSize: 18)),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Home screen: large tappable camera icon; opens CameraPreviewScreen on tap.
class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FlutterTts _flutterTts = FlutterTts();

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _flutterTts.awaitSpeakCompletion(false);
      await _flutterTts.setLanguage('en-US');
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.setVolume(1.0);
      await _flutterTts.setPitch(1.0);
      await Future.delayed(const Duration(milliseconds: 1500));
      await _speak();
    } catch (_) {}
  }

  Future<void> _speak() async {
    try {
      _flutterTts.speak(
        'Press the camera icon to open the camera and start navigating',
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: GestureDetector(
            onTap: () {
              try {
                _flutterTts.speak(
                  'Please point the camera towards the path ahead.',
                );
              } catch (_) {}
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CameraPreviewScreen(cameras: widget.cameras),
                ),
              );
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final shortest = constraints.maxWidth < constraints.maxHeight
                    ? constraints.maxWidth
                    : constraints.maxHeight;
                final size = shortest * 0.8;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: size,
                      height: size,
                      child: CircleAvatar(
                        radius: size / 2,
                        backgroundColor: Colors.black,
                        child: Icon(
                          Icons.camera_alt,
                          size: size * 0.5,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text('Open Camera', style: TextStyle(fontSize: 18)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
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
  bool _obstacleCheckInFlight = false; // prevent overlapping Gemini calls

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
      if (mounted) {
        _announceToScreenReader(
          _voiceService.isConnected
              ? 'Voice agent connected. Say where you want to go or ask where you are.'
              : 'Voice agent disconnected.',
        );
      }
    } catch (e, st) {
      debugPrint('Voice connect error: $e $st');
      if (mounted) {
        setState(() {
          _voiceError = e.toString();
        });
        _announceToScreenReader('Voice connection failed. ${e.toString()}');
      }
    } finally {
      if (mounted) {
        setState(() => _voiceConnecting = false);
      }
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
    final u = Uri.parse(
        tokenUrl.trim().isEmpty ? 'http://localhost:8765/token' : tokenUrl);
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
    _obstacleHapticTimer =
        Timer.periodic(Duration(milliseconds: obstacleHapticPeriodMs), (_) {
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
      _announceToScreenReader(
          'Object detection turned on. You will feel vibrations and hear alerts when something is in front.');
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
    if (_obstacleCheckInFlight) return;
    final controller = _controller;
    if (!mounted || controller == null || !controller.value.isInitialized)
      return;

    _obstacleCheckInFlight = true;
    try {
      final xfile = await controller.takePicture();
      List<int> bytes = await xfile.readAsBytes();
      if (!mounted || bytes.isEmpty) {
        debugPrint('Obstacle: no image bytes from camera');
        _obstacleCheckInFlight = false;
        return;
      }

      bytes = _resizeObstacleImage(bytes);
      debugPrint('Obstacle: frame ${bytes.length} bytes');

      Map<String, dynamic>? body;
      if (useLocalObstacleDetection && googleApiKey.trim().isNotEmpty) {
        body = await _analyzeObstacleLocal(bytes);
      } else {
        final url = _obstacleFrameUrl;
        if (url.isEmpty) return;
        final response = await http.post(
          Uri.parse(url),
          body: bytes,
          headers: {'Content-Type': 'image/jpeg'},
        ).timeout(Duration(seconds: obstacleRequestTimeoutSeconds));
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

      if (!mounted) {
        _obstacleCheckInFlight = false;
        return;
      }
      if (body == null) {
        debugPrint('Obstacle: no result from Gemini/server');
        _obstacleCheckInFlight = false;
        return;
      }
      if (!_obstacleDetectionOn) return;
      final detected = body['obstacle_detected'] == true;
      final distance =
          (body['distance'] as String? ?? '').toString().toLowerCase();
      final description =
          (body['description'] as String? ?? '').toString().trim();
      final isNear = detected && obstacleAlertDistances.contains(distance);

      if (!mounted || !_obstacleDetectionOn) return;
      final wasNear = _obstacleNear;
      setState(() {
        _obstacleNear = isNear;
        _obstacleDescription =
            isNear ? (description.isNotEmpty ? description : 'obstacle') : null;
      });
      if (!_obstacleDetectionOn) return;
      if (isNear) {
        _startObstacleAlerts(description.isNotEmpty ? description : 'object');
        final desc = description.isNotEmpty ? description : 'object';
        final now = DateTime.now();
        final shouldAnnounce = !wasNear ||
            _lastObstacleAnnounceTime == null ||
            now.difference(_lastObstacleAnnounceTime!) >
                Duration(seconds: obstacleAnnounceCooldownSeconds);
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
    } catch (e) {
      debugPrint('Obstacle check error: $e');
      if (mounted && _obstacleDetectionOn) {
        setState(() {
          _obstacleNear = false;
          _obstacleDescription = null;
        });
      }
    } finally {
      _obstacleCheckInFlight = false;
    }
  }

  /// Resize JPEG for fast upload and inference.
  List<int> _resizeObstacleImage(List<int> imageBytes) {
    if (obstacleImageMaxWidth <= 0) return imageBytes;
    try {
      final decoded = img.decodeImage(Uint8List.fromList(imageBytes));
      if (decoded == null || decoded.width <= obstacleImageMaxWidth)
        return imageBytes;
      final resized = img.copyResize(decoded, width: obstacleImageMaxWidth);
      final encoded = img.encodeJpg(resized, quality: obstacleJpegQuality);
      return encoded;
    } catch (_) {
      return imageBytes;
    }
  }

  /// Call Gemini API directly from the app (no obstacle server). Model cached for speed.
  Future<Map<String, dynamic>?> _analyzeObstacleLocal(
      List<int> imageBytes) async {
    if (imageBytes.isEmpty) {
      debugPrint('Obstacle Gemini: skipped empty image');
      return null;
    }
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
      if (text.isEmpty) {
        debugPrint(
            'Obstacle Gemini: empty response (candidates: ${response.candidates.length})');
        return null;
      }
      String jsonStr = text;
      if (text.contains('```')) {
        final start = text.indexOf('{');
        final end = text.lastIndexOf('}') + 1;
        if (start >= 0 && end > start) jsonStr = text.substring(start, end);
      }
      final out = jsonDecode(jsonStr) as Map<String, dynamic>?;
      if (out == null) return null;
      if (kDebugMode) {
        debugPrint('Obstacle Gemini: $out');
      }
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
      if (dist != 'far' && dist != 'medium' && dist != 'near')
        dist = det ? 'medium' : 'none';
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
      path =
          '${dir.path}/mic_test_${DateTime.now().millisecondsSinceEpoch}.m4a';
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
    parts.add(_obstacleDetectionOn
        ? 'Object detection: on'
        : 'Object detection: off');
    return parts.join('. ');
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    final showCamera = controller != null && controller.value.isInitialized;
    final padding = MediaQuery.of(context).padding;
    return Scaffold(
      body: _initializing && controller == null
          ? Container(
              color: Colors.black,
              alignment: Alignment.center,
              child:
                  Text(_status, style: const TextStyle(color: Colors.white)),
            )
          : Stack(
              children: [
                Positioned.fill(
                  child: showCamera
                        ? ExcludeSemantics(
                            child: _CameraPreviewFullScreen(
                                controller: controller),
                          )
                        : Container(
                            color: Colors.black,
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    color: Colors.white54,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(_status,
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.8),
                                        fontSize: 16)),
                              ],
                            ),
                          ),
                ),

                  // Status + GPS overlay — inset by safe area (hole punch, status bar)
                  Positioned(
                    left: 16 + padding.left,
                    right: 16 + padding.right,
                    top: 16 + padding.top,
                    child: Semantics(
                      container: true,
                      label: _statusSummaryForAccessibility(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.68),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.4), width: 1),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _status,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.2,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _locationLine(),
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.9),
                                          fontSize: 14,
                                          fontWeight: FontWeight.w400,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_heading != null) ...[
                                  const SizedBox(width: 12),
                                  Semantics(
                                    label: _headingLabel(_heading!),
                                    container: true,
                                    child: _CompassWidget(heading: _heading!),
                                  ),
                                ],
                              ],
                            ),
                            if (_obstacleNear &&
                                _obstacleDescription != null) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded,
                                      color: Colors.amber.shade200, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Obstacle: $_obstacleDescription',
                                      style: TextStyle(
                                        color: Colors.amber.shade100,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (_voiceError != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                'Voice: $_voiceError',
                                style: TextStyle(
                                    color: Colors.red.shade200, fontSize: 14),
                              ),
                            ] else ...[
                              const SizedBox(height: 10),
                              Text(
                                _voiceConnecting
                                    ? 'Voice: connecting…'
                                    : _voiceService.isConnected
                                        ? 'Voice: on'
                                        : 'Voice: off (tap mic to start)',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              // Mic level: test when not connected, or "live" when connected
                              const SizedBox(height: 10),
                              if (_micTesting) ...[
                                Row(
                                  children: [
                                    SizedBox(
                                      width: 100,
                                      height: 6,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(3),
                                        child: LinearProgressIndicator(
                                          value: _micLevel ?? 0,
                                          backgroundColor:
                                              Colors.white.withOpacity(0.25),
                                          valueColor:
                                              const AlwaysStoppedAnimation<
                                                  Color>(Color(0xFF34C759)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Mic: ${((_micLevel ?? 0) * 100).toStringAsFixed(0)}%',
                                      style: TextStyle(
                                          color: Colors.white.withOpacity(0.9),
                                          fontSize: 13),
                                    ),
                                    const Spacer(),
                                    Semantics(
                                      label: 'Stop mic test',
                                      hint: 'Double tap to stop listening',
                                      button: true,
                                      child: GestureDetector(
                                        onTap: _stopMicTest,
                                        behavior: HitTestBehavior.opaque,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 10),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.white.withOpacity(0.25),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: const Text('Stop',
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w600)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Listening… speak to test (stops in 15s or tap Stop)',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                      fontSize: 12),
                                ),
                              ] else if (!_voiceService.isConnected &&
                                  !_voiceConnecting) ...[
                                Semantics(
                                  label: 'Test mic level',
                                  hint:
                                      'Double tap to test your microphone before connecting',
                                  button: true,
                                  child: GestureDetector(
                                    onTap: _startMicTest,
                                    behavior: HitTestBehavior.opaque,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                            color:
                                                Colors.white.withOpacity(0.3)),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.mic_none,
                                              size: 20, color: Colors.white),
                                          SizedBox(width: 10),
                                          Text('Test mic level',
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500)),
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
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF34C759),
                                        shape: BoxShape.circle,
                                        boxShadow: [
                                          BoxShadow(
                                              color: const Color(0xFF34C759)
                                                  .withOpacity(0.6),
                                              blurRadius: 6)
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Mic live (sending to agent)',
                                      style: TextStyle(
                                          color: Colors.white.withOpacity(0.9),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Icon(
                                    Icons.warning_amber_rounded,
                                    size: 16,
                                    color: _obstacleDetectionOn
                                        ? Colors.amber.shade200
                                        : Colors.white.withOpacity(0.7),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      _obstacleDetectionOn
                                          ? 'Object detection: on'
                                          : _voiceService.isConnected
                                              ? 'Object detection: off (tap ⚠ to turn on)'
                                              : 'Object detection: connect voice first',
                                      style: TextStyle(
                                        color: _obstacleDetectionOn
                                            ? Colors.amber.shade100
                                            : Colors.white.withOpacity(0.8),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (kIsWeb &&
                                  !_voiceService.isConnected &&
                                  !_voiceConnecting) ...[
                                const SizedBox(height: 6),
                                Text(
                                  'Chrome: allow mic when prompted. After connecting, tap "Tap to enable speaker" if you can\'t hear.',
                                  style: TextStyle(
                                      color: Colors.white.withOpacity(0.7),
                                      fontSize: 12),
                                ),
                              ],
                              if (_voiceService.audioPlaybackFailed ||
                                  (kIsWeb && _voiceService.isConnected)) ...[
                                if (kIsWeb) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Chrome: allow microphone when prompted. If you can\'t hear the agent, tap below.',
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 13),
                                  ),
                                ],
                                const SizedBox(height: 10),
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
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 14),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade400
                                            .withOpacity(0.9),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                            color:
                                                Colors.white.withOpacity(0.2)),
                                      ),
                                      child: Center(
                                        child: Text(
                                          _voiceService.audioPlaybackFailed
                                              ? 'Tap to enable speaker (Chrome)'
                                              : 'Tap to enable speaker',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600),
                                        ),
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

                  // Bottom bar — inset by safe area (nav bar)
                  Positioned(
                    left: 16 + padding.left,
                    right: 16 + padding.right,
                    bottom: 20 + padding.bottom,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(32),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(32),
                            border: Border.all(
                                color: Colors.white.withOpacity(0.45), width: 1),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.35),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Voice — left
                              Expanded(
                                child: Semantics(
                                  label: _voiceConnecting
                                      ? 'Voice agent. Connecting.'
                                      : (_voiceService.isConnected
                                          ? 'Voice agent. On. Double tap to disconnect.'
                                          : 'Voice agent. Off. Double tap to connect.'),
                                  hint: _voiceConnecting
                                      ? null
                                      : 'Double tap to turn voice assistant on or off',
                                  button: true,
                                  enabled: !_voiceConnecting,
                                  child: Material(
                                    color: _voiceService.isConnected &&
                                            !_voiceConnecting
                                        ? const Color(0xFF34C759).withOpacity(0.5)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(26),
                                    child: InkWell(
                                      onTap: _voiceConnecting
                                          ? null
                                          : _onVoiceButtonPressed,
                                      borderRadius: BorderRadius.circular(26),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 48, horizontal: 16),
                                        alignment: Alignment.center,
                                        child: _voiceConnecting
                                            ? const SizedBox(
                                                width: 36,
                                                height: 36,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2.5,
                                                  color: Colors.white,
                                                ),
                                              )
                                            : Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.mic_rounded,
                                                    size: 36,
                                                    color:
                                                        _voiceService.isConnected
                                                            ? Colors.white
                                                            : Colors.white
                                                                .withOpacity(0.9),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Flexible(
                                                    child: Text(
                                                      'Voice',
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 22,
                                                        fontWeight: FontWeight.w600,
                                                        color: _voiceService
                                                                .isConnected
                                                            ? Colors.white
                                                            : Colors.white
                                                                .withOpacity(0.9),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                width: 1,
                                margin: const EdgeInsets.symmetric(horizontal: 6),
                                color: Colors.white.withOpacity(0.4),
                              ),
                              // Obstacles — right
                              Expanded(
                                child: Semantics(
                                  label: _voiceService.isConnected
                                      ? (_obstacleDetectionOn
                                          ? 'Object detection. On. Double tap to turn off.'
                                          : 'Object detection. Off. Double tap to turn on.')
                                      : 'Object detection. Connect voice first.',
                                  hint: _voiceService.isConnected
                                      ? 'Double tap to toggle obstacle alerts'
                                      : null,
                                  button: true,
                                  enabled: _voiceService.isConnected,
                                  child: Material(
                                    color: _obstacleDetectionOn &&
                                            _voiceService.isConnected
                                        ? Colors.orange.withOpacity(0.45)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(26),
                                    child: InkWell(
                                      onTap: _voiceService.isConnected
                                          ? _onObstacleDetectionToggle
                                          : null,
                                      borderRadius: BorderRadius.circular(26),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 48, horizontal: 16),
                                        alignment: Alignment.center,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.warning_amber_rounded,
                                              size: 36,
                                              color: _voiceService.isConnected
                                                  ? (_obstacleDetectionOn
                                                      ? Colors.white
                                                      : Colors.white
                                                          .withOpacity(0.85))
                                                  : Colors.white.withOpacity(0.4),
                                            ),
                                            const SizedBox(width: 10),
                                            Flexible(
                                              child: Text(
                                                'Obstacles',
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 22,
                                                  fontWeight: FontWeight.w600,
                                                  color: _voiceService.isConnected
                                                      ? (_obstacleDetectionOn
                                                          ? Colors.white
                                                          : Colors.white
                                                              .withOpacity(0.9))
                                                      : Colors.white
                                                          .withOpacity(0.4),
                                                ),
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
                      ),
                    ),
                  ),
              ],
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
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
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

/// Compass — iOS-style frosted circle, N at top, needle points in direction of travel.
class _CompassWidget extends StatelessWidget {
  final double heading; // 0 = north, 90 = east (degrees)

  const _CompassWidget({required this.heading});

  @override
  Widget build(BuildContext context) {
    const double size = 56;
    return ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withOpacity(0.2),
            border:
                Border.all(color: Colors.white.withOpacity(0.4), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: CustomPaint(
            size: const Size(size, size),
            painter: _CompassPainter(heading: heading),
          ),
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
      final pos = center +
          Offset(radius * 0.75 * math.cos(rad), radius * 0.75 * math.sin(rad));
      final p = TextPainter(
        text: TextSpan(
            text: label,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
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
    canvas.drawPath(
        needlePath,
        Paint()
          ..color = Colors.orange
          ..style = PaintingStyle.fill);
    canvas.drawPath(
        needlePath,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) => old.heading != heading;
}
