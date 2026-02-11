import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, debugPrint, compute, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'config.dart';
import 'voice_service.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Runs in background isolate to avoid blocking the camera preview.
Uint8List? _resizeObstacleImageIsolate(Uint8List jpegBytes) {
  const maxBytes = 10000;
  try {
    final decoded = img.decodeImage(jpegBytes);
    if (decoded == null) return null;
    final w = decoded.width;
    final h = decoded.height;
    final cropW = (w * 0.8).round();
    final cropH = (h * 0.8).round();
    final x = (w - cropW) ~/ 2;
    final y = (h - cropH) ~/ 2;
    final cropped =
        img.copyCrop(decoded, x: x, y: y, width: cropW, height: cropH);
    final scale = obstacleImageMaxWidth / cropped.width;
    final resized = img.copyResize(
      cropped,
      width: obstacleImageMaxWidth,
      height: (cropped.height * scale).round(),
    );
    for (final q in [obstacleJpegQuality, 35, 25, 20, 15]) {
      final encoded = img.encodeJpg(resized, quality: q);
      final bytes = Uint8List.fromList(encoded);
      if (bytes.length <= maxBytes) return bytes;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Arguments for _processBgraFrameForObstacle (for compute isolate).
class _ProcessBgraArgs {
  const _ProcessBgraArgs(
    this.planeBytes,
    this.width,
    this.height,
    this.bytesPerRow,
    this.bytesOffset,
  );
  final Uint8List planeBytes;
  final int width;
  final int height;
  final int bytesPerRow;
  final int bytesOffset;
}

/// Converts BGRA8888 CameraImage to resized JPEG bytes (no shutter sound).
/// Used when obstacle detection is on - avoids takePicture() which triggers iOS shutter sound.
Uint8List? _processBgraFrameForObstacle(_ProcessBgraArgs args) {
  final planeBytes = args.planeBytes;
  final width = args.width;
  final height = args.height;
  final bytesPerRow = args.bytesPerRow;
  final bytesOffset = args.bytesOffset;
  const maxBytes = 10000;
  try {
    final decoded = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: planeBytes.buffer,
      bytesOffset: bytesOffset,
      rowStride: bytesPerRow,
      order: img.ChannelOrder.bgra,
      numChannels: 4,
    );
    final w = decoded.width;
    final h = decoded.height;
    final cropW = (w * 0.8).round();
    final cropH = (h * 0.8).round();
    final x = (w - cropW) ~/ 2;
    final y = (h - cropH) ~/ 2;
    final cropped =
        img.copyCrop(decoded, x: x, y: y, width: cropW, height: cropH);
    final scale = obstacleImageMaxWidth / cropped.width;
    final resized = img.copyResize(
      cropped,
      width: obstacleImageMaxWidth,
      height: (cropped.height * scale).round(),
    );
    for (final q in [obstacleJpegQuality, 35, 25, 20, 15]) {
      final encoded = img.encodeJpg(resized, quality: q);
      final bytes = Uint8List.fromList(encoded);
      if (bytes.length <= maxBytes) return bytes;
    }
    return null;
  } catch (_) {
    return null;
  }
}

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

  // Navigation: voice agent + GPS for turn-by-turn
  final VoiceService _voiceService = VoiceService();
  bool _navigationOn = false;
  bool _voiceConnecting = false;
  String? _voiceError;

  // Mic level indicator: test when not connected (record package)
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _micTesting = false;
  double? _micLevel; // 0..1 normalized from dBFS
  StreamSubscription<Amplitude>? _micLevelSub;

  // Obstacle detection: can run with or without navigation; sends frames to agent
  bool _obstacleDetectionOn = false;
  Timer? _obstacleTimer;
  Timer? _obstacleHapticTimer;
  Timer?
      _obstacleStaleTimer; // auto-clear if no update for a while (handles stuck)
  bool _obstacleCheckInProgress = false;
  bool _obstacleInFront = false;
  String _obstacleDescription = '';
  CameraImage? _latestObstacleFrame;
  bool _cameraFormatIsBgra = false; // true when using bgra8888 (silent capture)
  Timer? _obstacleBorderFlashTimer;
  bool _obstacleBorderFlashOn = false;

  @override
  void initState() {
    super.initState();
    _voiceService.addListener(_onVoiceStateChanged);
    _voiceService.onObstacleFromAgent = _onObstacleFromAgent;
    _start();
  }

  Future<void> _onNavigationButtonPressed() async {
    HapticFeedback.selectionClick();
    if (_voiceConnecting) return;
    setState(() {
      _voiceError = null;
      _voiceConnecting = true;
    });
    try {
      if (_navigationOn) {
        // Turn navigation OFF
        setState(() => _navigationOn = false);
        _voiceService.setNavigationEnabled(false);
        _voiceService.publishAppMode(navigation: false, obstacles: _obstacleDetectionOn);
        if (!_obstacleDetectionOn) {
          await _voiceService.disconnect();
        }
        if (mounted) _announceToScreenReader('Navigation off.');
      } else {
        // Turn navigation ON
        if (!_voiceService.isConnected) {
          await _voiceService.connect();
        }
        setState(() => _navigationOn = true);
        _voiceService.setNavigationEnabled(true);
        _voiceService.publishAppMode(navigation: true, obstacles: _obstacleDetectionOn);
        if (mounted) _announceToScreenReader('Navigation on. Say where you want to go or ask where you are.');
      }
    } catch (e, st) {
      debugPrint('Navigation connect error: $e $st');
      if (mounted) {
        setState(() {
          _voiceError = e.toString();
        });
        _announceToScreenReader('Connection failed. ${e.toString()}');
      }
    } finally {
      if (mounted) setState(() => _voiceConnecting = false);
    }
  }

  Future<void> _start() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _status = "No camera (e.g. macOS). GPS + navigation only.";
        _initializing = false;
      });
      await _startLocation();
      return;
    }

    final camera = widget.cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => widget.cameras.first,
    );

    // Use bgra8888 to allow startImageStream for obstacle detection without shutter sound (iOS).
    // Fall back to jpeg if bgra8888 is not supported on the device.
    CameraController controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await controller.initialize();
      setState(() {
        _controller = controller;
        _initializing = false;
        _status = "Camera ready. Getting GPS…";
        _cameraFormatIsBgra = true;
      });

      // Start location after camera is ready (so UI feels responsive)
      await _startLocation();
    } on CameraException catch (_) {
      await controller.dispose();
      controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      try {
        await controller.initialize();
        if (mounted) {
          setState(() {
            _controller = controller;
            _initializing = false;
            _status = "Camera ready. Getting GPS…";
          });
          await _startLocation();
        }
      } on CameraException catch (e2) {
        if (mounted) {
          setState(() {
            _status = "Camera error: ${e2.code} ${e2.description}";
            _initializing = false;
          });
        }
      }
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

      // 4) Compass updates (heading 0–360) — push to agent immediately so nav uses current direction
      _compassSub?.cancel();
      _compassSub = FlutterCompass.events?.listen((CompassEvent e) {
        if (!mounted) return;
        if (e.heading != null) {
          setState(() => _heading = e.heading);
          if (_pos != null) {
            _voiceService.updateGps(
                _pos!.latitude, _pos!.longitude, e.heading!);
            _voiceService.publishGpsNow();
          }
        }
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
    if (!_voiceService.isConnected) {
      _stopObstacleDetection();
    }
    setState(() {});
  }

  void _onObstacleFromAgent(bool detected, String description) {
    if (!mounted) return;
    debugPrint('Obstacle: detected=$detected desc="$description"');
    _obstacleStaleTimer?.cancel();
    _obstacleBorderFlashTimer?.cancel();
    setState(() {
      _obstacleInFront = detected;
      _obstacleDescription = description;
      _obstacleBorderFlashOn = false;
    });
    if (detected) {
      _obstacleBorderFlashTimer = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) {
          if (!mounted || !_obstacleInFront) return;
          setState(() => _obstacleBorderFlashOn = !_obstacleBorderFlashOn);
        },
      );
      _startObstacleHaptics();
      _obstacleStaleTimer = Timer(
        const Duration(milliseconds: obstacleStaleClearMs),
        () {
          if (!mounted || !_obstacleDetectionOn) return;
          _obstacleStaleTimer?.cancel();
          _obstacleStaleTimer = null;
          _obstacleBorderFlashTimer?.cancel();
          _obstacleBorderFlashTimer = null;
          setState(() {
            _obstacleInFront = false;
            _obstacleDescription = '';
            _obstacleBorderFlashOn = false;
          });
          _stopObstacleHaptics();
        },
      );
    } else {
      _obstacleBorderFlashTimer?.cancel();
      _obstacleBorderFlashTimer = null;
      _stopObstacleHaptics();
    }
  }

  Future<void> _startObstacleDetection() async {
    if (_obstacleDetectionOn) return;
    if (!_voiceService.isConnected) {
      if (_voiceConnecting) return;
      setState(() {
        _voiceError = null;
        _voiceConnecting = true;
      });
      try {
        await _voiceService.connect();
        _voiceService.setNavigationEnabled(_navigationOn);
        if (mounted) setState(() {});
      } catch (e, st) {
        debugPrint('Obstacle connect error: $e $st');
        if (mounted) {
          setState(() {
            _voiceError = e.toString();
            _voiceConnecting = false;
          });
        }
        return;
      } finally {
        if (mounted) setState(() => _voiceConnecting = false);
      }
    }
    _obstacleDetectionOn = true;
    _obstacleInFront = false;
    _obstacleDescription = '';
    _stopObstacleHaptics();
    _voiceService.publishObstacleMode(true, navigation: _navigationOn);
    _voiceService.publishAppMode(navigation: _navigationOn, obstacles: true);
    await _startObstacleImageStream();
    _obstacleTimer?.cancel();
    _obstacleTimer = Timer.periodic(
      const Duration(milliseconds: obstacleCheckIntervalMs),
      (_) => _runObstacleCheck(),
    );
    if (mounted) setState(() {});
  }

  void _stopObstacleDetection() {
    if (!_obstacleDetectionOn) return;
    _obstacleDetectionOn = false;
    _obstacleInFront = false;
    _obstacleBorderFlashTimer?.cancel();
    _obstacleBorderFlashTimer = null;
    _obstacleBorderFlashOn = false;
    unawaited(_stopObstacleImageStream());
    _obstacleDescription = '';
    _obstacleTimer?.cancel();
    _obstacleTimer = null;
    _obstacleStaleTimer?.cancel();
    _obstacleStaleTimer = null;
    _stopObstacleHaptics();
    _voiceService.publishObstacleMode(false, navigation: _navigationOn);
    _voiceService.publishAppMode(navigation: _navigationOn, obstacles: false);
    if (!_navigationOn && _voiceService.isConnected) {
      _voiceService.disconnect();
    }
    if (mounted) setState(() {});
  }

  void _startObstacleHaptics() {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = Timer.periodic(
      const Duration(milliseconds: obstacleHapticPeriodMs),
      (_) {
        HapticFeedback.heavyImpact();
        Future.delayed(
          const Duration(milliseconds: 50),
          () => HapticFeedback.heavyImpact(),
        );
      },
    );
  }

  void _stopObstacleHaptics() {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = null;
  }

  Future<void> _startObstacleImageStream() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || !_cameraFormatIsBgra) return;
    try {
      _latestObstacleFrame = null;
      await ctrl.startImageStream((CameraImage image) {
        _latestObstacleFrame = image;
      });
    } catch (_) {}
  }

  Future<void> _stopObstacleImageStream() async {
    final ctrl = _controller;
    if (ctrl != null && ctrl.value.isInitialized) {
      try {
        await ctrl.stopImageStream();
      } catch (_) {}
    }
    _latestObstacleFrame = null;
  }

  Future<void> _runObstacleCheck() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        !_obstacleDetectionOn) {
      return;
    }
    if (_obstacleCheckInProgress) return;
    _obstacleCheckInProgress = true;
    try {
      Uint8List? resized;
      if (_cameraFormatIsBgra && _latestObstacleFrame != null) {
        // Use image stream (no shutter sound on iOS)
        final frame = _latestObstacleFrame!;
        if (frame.planes.isNotEmpty) {
          final plane = frame.planes[0];
          final bytesOffset =
              defaultTargetPlatform == TargetPlatform.iOS ? 28 : 0;
          resized = await compute(
            _processBgraFrameForObstacle,
            _ProcessBgraArgs(
              plane.bytes,
              frame.width,
              frame.height,
              plane.bytesPerRow,
              bytesOffset,
            ),
          );
        }
      }
      if (resized == null || resized.isEmpty) {
        // Fallback to takePicture (plays shutter sound on iOS)
        final XFile file = await controller.takePicture();
        final bytes = await file.readAsBytes();
        resized = await compute(_resizeObstacleImageIsolate, bytes);
      }
      if (resized != null && resized.isNotEmpty) {
        final base64 = base64Encode(resized);
        _voiceService.publishObstacleFrame(base64);
      }
    } catch (_) {
    } finally {
      if (mounted) _obstacleCheckInProgress = false;
    }
  }


  void _onObstacleDetectionToggle() {
    HapticFeedback.selectionClick();
    if (_obstacleDetectionOn) {
      _stopObstacleDetection();
      _announceToScreenReader('Object detection off');
    } else {
      unawaited(_startObstacleDetection());
      _announceToScreenReader('Object detection on. Point camera ahead.');
    }
  }

  void _announceToScreenReader(String message) {
    try {
      SemanticsService.announce(message, TextDirection.ltr);
    } catch (_) {
      // Announce not supported on this platform
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
    _stopObstacleDetection();
    _stopMicTest();
    _voiceService.removeListener(_onVoiceStateChanged);
    _voiceService.onObstacleFromAgent = null;
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
    if (_voiceError != null) {
      parts.add('Connection error: $_voiceError');
    } else if (_voiceConnecting) {
      parts.add('Connecting');
    } else if (_voiceService.isConnected) {
      parts.add('Navigation: ${_navigationOn ? "on" : "off"}');
      parts.add('Object detection: ${_obstacleDetectionOn ? "on" : "off"}');
    } else {
      parts.add('Not connected');
    }
    if (_obstacleDetectionOn && _obstacleInFront) {
      parts.add('Obstacle ahead: $_obstacleDescription');
    }
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
              child: Text(_status, style: const TextStyle(color: Colors.white)),
            )
          : Stack(
              children: [
                // Obstacle warning overlay
                if (_obstacleInFront && _obstacleDescription.isNotEmpty)
                  Positioned(
                    left: 24 + padding.left,
                    right: 24 + padding.right,
                    bottom: 140 + padding.bottom,
                    child: Semantics(
                      liveRegion: true,
                      label: 'Obstacle ahead: $_obstacleDescription',
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade700.withOpacity(0.95),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded,
                                size: 36, color: Colors.white),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Text(
                                'Obstacle: $_obstacleDescription',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: showCamera
                      ? ExcludeSemantics(
                          child:
                              _CameraPreviewFullScreen(controller: controller),
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
                          color: _obstacleInFront
                              ? (_obstacleBorderFlashOn
                                  ? Colors.orange
                                  : Colors.orange.withOpacity(0.5))
                              : Colors.white.withOpacity(0.4),
                          width: _obstacleInFront ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                          if (_voiceError != null) ...[
                            const SizedBox(height: 10),
                            Text(
                              'Connection: $_voiceError',
                              style: TextStyle(
                                  color: Colors.red.shade200, fontSize: 14),
                            ),
                          ] else ...[
                            const SizedBox(height: 10),
                            Text(
                              _voiceConnecting
                                  ? 'Connecting…'
                                  : _voiceService.isConnected
                                      ? 'Connected'
                                      : 'Tap Navigation or Obstacles to start',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (_obstacleDetectionOn) ...[
                              const SizedBox(height: 4),
                              Text(
                                _obstacleInFront
                                    ? 'Obstacle: $_obstacleDescription'
                                    : 'Object detection: scanning',
                                style: TextStyle(
                                  color: _obstacleInFront
                                      ? Colors.orange
                                      : Colors.white.withOpacity(0.9),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
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
                                            const AlwaysStoppedAnimation<Color>(
                                                Color(0xFF34C759)),
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
                                          color: Colors.white.withOpacity(0.25),
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
                                          color: Colors.white.withOpacity(0.3)),
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
                                          color: Colors.white.withOpacity(0.2)),
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
                            // Navigation — left
                            Expanded(
                              child: Semantics(
                                label: _voiceConnecting
                                    ? 'Navigation. Connecting.'
                                    : (_navigationOn
                                        ? 'Navigation. On. Double tap to turn off.'
                                        : 'Navigation. Off. Double tap to turn on.'),
                                hint: _voiceConnecting
                                    ? null
                                    : 'Double tap to turn navigation on or off',
                                button: true,
                                enabled: !_voiceConnecting,
                                child: Material(
                                  color: _navigationOn && !_voiceConnecting
                                      ? const Color(0xFF34C759).withOpacity(0.5)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(26),
                                  child: InkWell(
                                    onTap: _voiceConnecting
                                        ? null
                                        : _onNavigationButtonPressed,
                                    borderRadius: BorderRadius.circular(26),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 32, horizontal: 12),
                                      alignment: Alignment.center,
                                      child: _voiceConnecting &&
                                              !_voiceService.isConnected
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
                                                  Icons.navigation_rounded,
                                                  size: 26,
                                                  color: _navigationOn
                                                      ? Colors.white
                                                      : Colors.white
                                                          .withOpacity(0.9),
                                                ),
                                                const SizedBox(width: 8),
                                                Flexible(
                                                  child: Text(
                                                    'Navigation',
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: _navigationOn
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
                            // Obstacles — right (always shown)
                            ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: Semantics(
                                  label: _obstacleDetectionOn
                                      ? 'Object detection. On. Double tap to turn off.'
                                      : 'Object detection. Off. Double tap to turn on.',
                                  hint: 'Double tap to detect obstacles ahead',
                                  button: true,
                                  child: Material(
                                    color: _obstacleDetectionOn
                                        ? Colors.orange.withOpacity(0.5)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(26),
                                    child: InkWell(
                                      onTap: _onObstacleDetectionToggle,
                                      borderRadius: BorderRadius.circular(26),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 32, horizontal: 12),
                                        alignment: Alignment.center,
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.warning_amber_rounded,
                                              size: 26,
                                              color: _obstacleDetectionOn
                                                  ? Colors.white
                                                  : Colors.white
                                                      .withOpacity(0.9),
                                            ),
                                            const SizedBox(width: 8),
                                            Flexible(
                                              child: Text(
                                                'Obstacles',
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w600,
                                                  color: _obstacleDetectionOn
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
                            ],
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
/// Uses buildPreview() + FittedBox so the texture gets explicit dimensions
/// and scales correctly without stretching.
class _CameraPreviewFullScreen extends StatelessWidget {
  final CameraController controller;

  const _CameraPreviewFullScreen({required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    final orientation = MediaQuery.of(context).orientation;
    final previewSize = controller.value.previewSize;

    if (previewSize == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    // Camera sensor is landscape; swap for portrait so preview matches device
    final w = orientation == Orientation.portrait
        ? previewSize.height
        : previewSize.width;
    final h = orientation == Orientation.portrait
        ? previewSize.width
        : previewSize.height;

    return Container(
      color: Colors.black,
      child: ClipRect(
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: SizedBox(
            width: w,
            height: h,
            child: controller.buildPreview(),
          ),
        ),
      ),
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
    void textPainter(String label, double angleDeg) {
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
    }
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
