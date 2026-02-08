import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:image/image.dart' as img;

import 'config.dart';
import 'voice_service.dart';

const String _tokenServerUrlKey = 'token_server_url';

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

  // Token server URL: on device use your computer's IP (e.g. http://192.168.1.x:8765/token)
  String? _tokenServerUrl;

  // Obstacle detection: same server as token, POST camera frame -> Gemini -> haptics by distance
  bool _obstacleDetectionOn = false;
  Timer? _obstacleTimer;
  Timer? _obstacleHapticTimer; // repeating haptic while obstacle is sensed
  bool _obstacleRequestInProgress = false;
  String? _obstacleError; // transient message when obstacle is on and request failed

  @override
  void initState() {
    super.initState();
    _voiceService.addListener(_onVoiceStateChanged);
    _loadTokenServerUrl();
    _start();
  }

  Future<void> _loadTokenServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_tokenServerUrlKey);
    if (mounted) setState(() => _tokenServerUrl = saved?.trim().isEmpty == true ? null : saved);
  }

  String get _effectiveTokenUrl => (_tokenServerUrl ?? tokenUrl).trim().isEmpty ? tokenUrl : (_tokenServerUrl ?? tokenUrl);

  /// Obstacle server is separate (only API key); same host, different port (see config.dart).
  String get _obstacleEndpointUrl {
    final u = _effectiveTokenUrl;
    final uri = Uri.parse(u);
    return '${uri.scheme}://${uri.host}:${obstacleServerPort}/obstacle-frame';
  }

  Future<void> _saveTokenServerUrl(String url) async {
    final trimmed = url.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove(_tokenServerUrlKey);
      if (mounted) setState(() => _tokenServerUrl = null);
    } else {
      await prefs.setString(_tokenServerUrlKey, trimmed);
      if (mounted) setState(() => _tokenServerUrl = trimmed);
    }
  }

  Future<void> _showSetServerUrlDialog() async {
    final controller = TextEditingController(text: _tokenServerUrl ?? tokenUrl);
    if (!mounted) return;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Token server URL'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'On a physical device, use your computer\'s IP so the app can reach the token server.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'http://192.168.1.x:8765/token',
                border: OutlineInputBorder(),
              ),
              autocorrect: false,
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              Navigator.pop(context, null);
            },
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              Navigator.pop(context, controller.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) await _saveTokenServerUrl(result);
  }

  static bool _isConnectionRefused(dynamic e) {
    final s = e.toString().toLowerCase();
    return s.contains('connection refused') || s.contains('socketexception') || s.contains('errno 111');
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
        await _voiceService.connect(tokenUrlOverride: _effectiveTokenUrl);
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
    if (mounted) setState(() => _voiceConnecting = false);
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
    if (mounted) {
      if (!_voiceService.isConnected && _obstacleDetectionOn) {
        _stopObstacleDetection();
      }
      setState(() {});
    }
  }

  void _startObstacleDetection() {
    if (!_voiceService.isConnected) return;
    _stopObstacleDetection();
    _obstacleDetectionOn = true;
    _obstacleTimer = Timer.periodic(const Duration(seconds: 2), (_) => _captureAndSendObstacleFrame());
    if (mounted) setState(() {});
  }

  void _stopObstacleDetection() {
    _obstacleTimer?.cancel();
    _obstacleTimer = null;
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = null;
    _obstacleDetectionOn = false;
    _obstacleError = null;
    if (mounted) setState(() {});
  }

  void _stopObstacleHaptic() {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = null;
    if (mounted) setState(() {});
  }

  void _startObstacleHaptic() {
    _obstacleHapticTimer?.cancel();
    _obstacleHapticTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!_obstacleDetectionOn) {
        _stopObstacleHaptic();
        return;
      }
      HapticFeedback.heavyImpact();
    });
    if (mounted) setState(() {});
  }

  Future<void> _captureAndSendObstacleFrame() async {
    if (_controller == null || !_controller!.value.isInitialized || !_obstacleDetectionOn || _obstacleRequestInProgress) return;
    _obstacleRequestInProgress = true;
    if (mounted) setState(() => _obstacleError = null);
    try {
      final XFile file = await _controller!.takePicture().timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('Camera capture'),
      );
      Uint8List bytes = await file.readAsBytes();
      if (!_obstacleDetectionOn) return;
      // Resize and compress so frame is always small enough for upload (obstacle detection doesn't need full res).
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        const maxWidth = 640;
        final resized = decoded.width > maxWidth
            ? img.copyResize(decoded, width: maxWidth)
            : decoded;
        bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 72));
      }
      if (bytes.length > 400000) {
        // Still too big; compress more
        final decoded2 = img.decodeImage(bytes);
        if (decoded2 != null) {
          bytes = Uint8List.fromList(img.encodeJpg(img.copyResize(decoded2, width: 480), quality: 60));
        }
      }
      final uri = Uri.parse(_obstacleEndpointUrl);
      final resp = await http.post(uri, body: bytes, headers: {'Content-Type': 'image/jpeg'}).timeout(const Duration(seconds: 10));
      if (!mounted || !_obstacleDetectionOn) return;
      if (resp.statusCode != 200) {
        _stopObstacleHaptic();
        if (mounted) setState(() => _obstacleError = 'Server ${resp.statusCode}');
        return;
      }
      final map = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (map == null) return;
      final rawDetected = map['obstacle_detected'];
      final detected = rawDetected == true ||
          (rawDetected is String && rawDetected.toString().trim().toLowerCase() == 'true');
      final distance = map['distance']?.toString().trim().toLowerCase() ?? 'none';
      final description = map['description']?.toString().trim() ?? '';
      // Only alert when very close and centered (~2 m) — i.e. distance "near" only.
      if (detected && distance == 'near') {
        _startObstacleHaptic(); // keep vibrating until next frame says clear
        _voiceService.publishObstacleAlert(distance, description);
      } else {
        _stopObstacleHaptic();
      }
    } catch (e) {
      _stopObstacleHaptic();
      if (mounted && _obstacleDetectionOn) {
        setState(() => _obstacleError = e is TimeoutException ? 'Camera busy' : 'No connection');
      }
    } finally {
      _obstacleRequestInProgress = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _stopMicTest() async {
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
    _stopObstacleDetection();
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
                        ? LayoutBuilder(
                            builder: (context, constraints) {
                              double aspectRatio = controller.value.aspectRatio;
                              if (aspectRatio <= 0) {
                                return CameraPreview(controller);
                              }
                              final w = constraints.maxWidth;
                              final h = constraints.maxHeight;
                              // On portrait, camera sensor is often landscape so preview is rotated; use inverse ratio.
                              final isPortrait = h > w;
                              if (isPortrait && aspectRatio > 1) {
                                aspectRatio = 1 / aspectRatio;
                              }
                              final deviceRatio = w / h;
                              double scale = aspectRatio / deviceRatio;
                              if (scale < 1) scale = 1 / scale;
                              return ClipRect(
                                child: OverflowBox(
                                  alignment: Alignment.center,
                                  child: Transform.scale(
                                    scale: scale,
                                    child: Center(
                                      child: AspectRatio(
                                        aspectRatio: aspectRatio,
                                        child: CameraPreview(controller),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          )
                        : Container(color: Colors.black87, child: Center(child: Text(_status, style: const TextStyle(color: Colors.white54)))),
                  ),

                  // Status + GPS overlay
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 12,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_status, style: const TextStyle(color: Colors.white)),
                          const SizedBox(height: 6),
                          Text(_locationLine(), style: const TextStyle(color: Colors.white)),
                          if (_voiceError != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              _isConnectionRefused(_voiceError)
                                  ? 'Voice: Can\'t reach token server. On a device, set your computer\'s IP below.'
                                  : 'Voice: $_voiceError',
                              style: const TextStyle(color: Colors.orangeAccent),
                            ),
                            if (_isConnectionRefused(_voiceError)) ...[
                              const SizedBox(height: 6),
                              GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  _showSetServerUrlDialog();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withValues(alpha: 0.9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    'Set server URL (e.g. http://YOUR_MAC_IP:8765/token)',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 12),
                                  ),
                                ),
                              ),
                            ],
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
                                  GestureDetector(
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      _stopMicTest();
                                    },
                                    child: Text(
                                      'Stop',
                                      style: TextStyle(color: Colors.orange.shade200, fontSize: 12),
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
                              GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  _startMicTest();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.mic_none, size: 18, color: Colors.white70),
                                      SizedBox(width: 6),
                                      Text('Test mic level', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
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
                            // Let user set token server URL (required on physical device = computer's IP)
                            if (!_voiceService.isConnected && !_voiceConnecting) ...[
                              const SizedBox(height: 6),
                              GestureDetector(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  _showSetServerUrlDialog();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.settings_ethernet, size: 14, color: Colors.white54),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Server: ${_tokenServerUrl ?? tokenUrl}',
                                      style: TextStyle(color: Colors.white54, fontSize: 11),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                    const SizedBox(width: 4),
                                    Text('Change', style: TextStyle(color: Colors.orange.shade200, fontSize: 11)),
                                  ],
                                ),
                              ),
                            ],
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
                              GestureDetector(
                                onTap: () async {
                                  HapticFeedback.selectionClick();
                                  await _voiceService.playbackAudio();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _voiceService.audioPlaybackFailed
                                        ? 'Tap to enable speaker (Chrome)'
                                        : 'Tap to enable speaker',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),

                  // Compass: direction you're facing (N/S/E/W)
                  if (_heading != null)
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: _CompassWidget(heading: _heading!),
                    ),

                  // Obstacle detection: camera frame -> server (Gemini) -> haptics by distance
                  if (showCamera)
                    Positioned(
                      left: 12,
                      bottom: 80,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_obstacleError != null && _obstacleDetectionOn) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              margin: const EdgeInsets.only(bottom: 4),
                              decoration: BoxDecoration(
                                color: Colors.black87,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _obstacleError!,
                                style: const TextStyle(color: Colors.orangeAccent, fontSize: 10),
                              ),
                            ),
                          ],
                          Material(
                            color: _voiceService.isConnected
                                ? (_obstacleDetectionOn ? Colors.orange.withValues(alpha: 0.9) : Colors.black54)
                                : Colors.black38,
                            borderRadius: BorderRadius.circular(8),
                            child: InkWell(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                if (_obstacleDetectionOn) {
                                  _stopObstacleDetection();
                                } else if (_voiceService.isConnected) {
                                  _startObstacleDetection();
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Enable the mic first to use obstacle detection'),
                                      duration: Duration(seconds: 2),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              },
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _obstacleDetectionOn ? Icons.vibration : Icons.warning_amber_rounded,
                                      color: _voiceService.isConnected ? Colors.white : Colors.white54,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _obstacleDetectionOn
                                          ? 'Obstacle: on'
                                          : (_voiceService.isConnected ? 'Obstacle' : 'Obstacle (mic first)'),
                                      style: TextStyle(
                                        color: _voiceService.isConnected ? Colors.white : Colors.white54,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // Voice agent toggle: on = connect (mic + GPS), off = disconnect (memory kept)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton(
                      onPressed: _voiceConnecting ? null : _onVoiceButtonPressed,
                      backgroundColor: _voiceService.isConnected ? Colors.green : null,
                      child: _voiceConnecting
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.mic),
                    ),
                  ),
                ],
              ),
      ),
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
