import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
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
      _voiceService.updateGps(first.latitude, first.longitude);

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
          _voiceService.updateGps(p.latitude, p.longitude);
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
    if (mounted) setState(() {});
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
    _stopMicTest();
    _voiceService.removeListener(_onVoiceStateChanged);
    _voiceService.disconnect();
    _posSub?.cancel();
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
                        ? CameraPreview(controller!)
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
                                onTap: _showSetServerUrlDialog,
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
                                    onTap: _stopMicTest,
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
                                onTap: _startMicTest,
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
                                onTap: _showSetServerUrlDialog,
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
