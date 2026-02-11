import 'dart:async';
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import 'config.dart';

/// Connects to LiveKit for voice agent, obstacle detection, or both.
/// GPS is published only when navigation mode is enabled.
/// When off: disconnects; memory is kept on the server (Backboard) and restored on next connect.
class VoiceService extends ChangeNotifier {
  Room? _room;
  Timer? _gpsTimer;
  double? _lat;
  double? _lng;
  double? _heading; // compass heading 0-360 (0 = north), for agent
  EventsListener<RoomEvent>? _roomListener;

  static const String _gpsTopic = 'gps';
  static const String _appModeTopic = 'app-mode';
  static const String _obstacleModeTopic = 'obstacle-mode';
  static const String _obstacleFrameTopic = 'obstacle-frame';
  static const String _obstacleDataTopic = 'obstacle';
  static const Duration _gpsInterval = Duration(seconds: 3);

  /// Called when agent reports obstacle detected or cleared.
  void Function(bool detected, String description)? onObstacleFromAgent;

  bool get isConnected => _room != null;

  /// True when Chrome (or browser) blocked playback; user must tap "Play agent audio" to hear.
  bool get audioPlaybackFailed => _audioPlaybackFailed;
  bool _audioPlaybackFailed = false;

  /// Call whenever position or compass heading updates so we can publish when connected.
  void updateGps(double lat, double lng, [double? heading]) {
    _lat = lat;
    _lng = lng;
    if (heading != null) _heading = heading;
  }

  bool _disconnecting = false;
  bool _navigationEnabled = false; // Publish GPS only when true

  /// Enable/disable GPS publishing (for navigation). Call when navigation mode toggles.
  void setNavigationEnabled(bool enabled) {
    if (_navigationEnabled == enabled) return;
    _navigationEnabled = enabled;
    if (enabled) {
      _startGpsPublishing();
    } else {
      _gpsTimer?.cancel();
      _gpsTimer = null;
    }
  }

  /// Fire-and-forget data publish with error handling. Avoids TimeoutException crashing the app.
  void _publishDataSafe(List<int> data, String topic) {
    final room = _room;
    if (room == null) return;
    final lp = room.localParticipant;
    if (lp == null) return;
    unawaited(
      lp.publishData(data, topic: topic).catchError((e, st) {
        debugPrint('VoiceService: publishData failed topic=$topic: $e');
      }),
    );
  }

  /// Generate a LiveKit JWT in-app (no token server). Includes roomConfig so LiveKit dispatches voice-agent when we join.
  String _makeLiveKitToken(String identity, String roomName) {
    final jwt = JWT(
      {
        'video': {
          'room': roomName,
          'roomJoin': true,
          'canPublish': true,
          'canSubscribe': true,
          'canPublishData': true,
        },
        // Dispatch voice-agent when participant connects (LiveKit expects camelCase in JWT)
        'roomConfig': {
          'agents': [
            {'agentName': 'voice-agent'},
          ],
        },
      },
      subject: identity,
      issuer: liveKitApiKey.trim(),
    );
    return jwt.sign(
      SecretKey(liveKitApiSecret.trim()),
      algorithm: JWTAlgorithm.HS256,
      expiresIn: const Duration(hours: 24),
    );
  }

  /// Connect to the voice agent (publish mic; start sending GPS). Memory from previous sessions is preserved on the server.
  /// If [useLocalLiveKitToken] is true (LiveKit URL + API key + secret in config), generates token in-app — no token server.
  /// Otherwise [tokenUrlOverride] or [tokenUrl] is used to fetch token (e.g. http://YOUR_COMPUTER_IP:8765/token).
  Future<void> connect({String? tokenUrlOverride}) async {
    if (_room != null) return;
    while (_disconnecting) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    String token;
    String url;

    if (useLocalLiveKitToken) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final identity = 'mobile-user-$now';
      final roomName = 'voice-nav-$now';
      token = _makeLiveKitToken(identity, roomName);
      url = liveKitUrl.trim();
      if (url.startsWith('http://')) url = 'ws${url.substring(4)}';
      if (url.startsWith('https://')) url = 'wss${url.substring(5)}';
      debugPrint(
          'VoiceService: connecting to $url room=$roomName (in-app token). Ensure agent.py uses same LIVEKIT_URL.');
    } else {
      final tokenServerUrl = (tokenUrlOverride ?? tokenUrl).trim();
      if (tokenServerUrl.isEmpty) {
        throw Exception(
            'LiveKit keys not set. Add LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET to .env.local and run with ./run_app.sh (in-app token, no server). Or set TOKEN_URL to your token server (e.g. http://YOUR_COMPUTER_IP:8765/token).');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final identity = 'mobile-user-$now';
      final roomName = 'voice-nav-$now';
      final uri = Uri.parse(tokenServerUrl).replace(
        queryParameters: {'identity': identity, 'room': roomName},
      );
      try {
        final resp = await http.get(uri);
        if (resp.statusCode != 200) {
          throw Exception('Token failed: ${resp.statusCode} ${resp.body}');
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final t = body['token'] as String?;
        final u = body['url'] as String?;
        if (t == null || t.isEmpty || u == null || u.isEmpty) {
          throw Exception('Invalid token response: missing token or url');
        }
        token = t;
        url = u;
        debugPrint(
            'VoiceService: connecting to token server room (url from server).');
      } catch (e) {
        if (uri.host == 'localhost' || uri.host == '127.0.0.1') {
          throw Exception(
              'Connection refused to $tokenServerUrl. On a device, localhost is the device itself. Use in-app token instead: add LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET to .env.local and run with ./run_app.sh.');
        }
        rethrow;
      }
    }

    try {
      final room = Room();
      _setUpRoomListeners(room);
      // Publish mic from the start; unique room per connect so each reconnect gets a new agent (Android closes connection if we add track later)
      await room.connect(
        url,
        token,
        fastConnectOptions: FastConnectOptions(
          microphone: const TrackOption(enabled: true),
        ),
      );

      _room = room;
      _audioPlaybackFailed = false;
      if (_navigationEnabled) _startGpsPublishing(); // Caller sets via setNavigationEnabled(true) for nav mode

      try {
        await room.startAudio();
      } catch (e) {
        debugPrint('VoiceService startAudio: $e');
      }

      debugPrint('VoiceService: connected to room ${room.name}');
      notifyListeners();
    } catch (e, st) {
      debugPrint('VoiceService.connect error: $e $st');
      rethrow;
    }
  }

  void _setUpRoomListeners(Room room) {
    _roomListener?.dispose();
    _roomListener = room.createListener()
      ..on<RoomDisconnectedEvent>((_) {
        if (_room == room) {
          _gpsTimer?.cancel();
          _gpsTimer = null;
          _room = null;
          _roomListener?.dispose();
          _roomListener = null;
          notifyListeners();
        }
      })
      ..on<TrackSubscribedEvent>((event) async {
        // When agent's audio track arrives, try to start playback (Chrome often blocks until user gesture)
        if (event.track.kind == TrackType.AUDIO) {
          try {
            await event.track.enable();
            await room.startAudio();
            // Give Chrome a moment to attach the element, then try again (helps if first play() was blocked)
            await Future<void>.delayed(const Duration(milliseconds: 150));
            await room.startAudio();
          } catch (e) {
            debugPrint('VoiceService TrackSubscribed startAudio: $e');
          }
        }
      })
      ..on<AudioPlaybackStatusChanged>((event) {
        if (!event.isPlaying) {
          _audioPlaybackFailed = true;
          notifyListeners();
        }
      })
      ..on<DataReceivedEvent>((event) {
        if (event.topic != _obstacleDataTopic) return;
        try {
          final json =
              jsonDecode(utf8.decode(event.data)) as Map<String, dynamic>;
          final detected = json['detected'] as bool? ?? false;
          final desc = (json['description'] as String? ?? '').toString();
          debugPrint('VoiceService: obstacle from agent: detected=$detected desc="$desc"');
          onObstacleFromAgent?.call(detected, desc);
        } catch (e) {
          debugPrint('VoiceService: obstacle parse error: $e');
        }
      });
  }

  /// Publish app mode so agent can pick the right greeting (nav vs obstacles-only).
  void publishAppMode({required bool navigation, required bool obstacles}) {
    final room = _room;
    if (room == null) return;
    final payload = utf8.encode('{"navigation":$navigation,"obstacles":$obstacles}');
    _publishDataSafe(payload, _appModeTopic);
  }

  /// Publish obstacle mode (enable/disable) to agent.
  /// Include [navigation] so agent knows if this is obstacles-only vs nav+obstacles.
  void publishObstacleMode(bool enabled, {required bool navigation}) {
    final room = _room;
    if (room == null) return;
    final payload = utf8.encode('{"enabled":$enabled,"navigation":$navigation}');
    _publishDataSafe(payload, _obstacleModeTopic);
    debugPrint('VoiceService: published obstacle-mode enabled=$enabled navigation=$navigation');
  }

  static int _obstacleFramesSent = 0;

  /// Publish a single camera frame (base64 JPEG) to agent.
  /// Payload must stay under 14KB for LiveKit reliable data (hard limit ~15KB).
  void publishObstacleFrame(String base64Jpeg) {
    final room = _room;
    if (room == null) return;
    final payload = utf8.encode('{"frame":"$base64Jpeg"}');
    if (payload.length > 14 * 1024) {
      debugPrint('VoiceService: obstacle frame too large (${payload.length} bytes > 14KB), skipping');
      return;
    }
    _publishDataSafe(payload, _obstacleFrameTopic);
    _obstacleFramesSent++;
    if (_obstacleFramesSent <= 2 || _obstacleFramesSent % 25 == 0) {
      debugPrint('VoiceService: obstacle frame sent #$_obstacleFramesSent (${payload.length} bytes)');
    }
  }

  void _startGpsPublishing() {
    _gpsTimer?.cancel();
    _gpsTimer = Timer.periodic(_gpsInterval, (_) => _publishGps());
    _publishGps(); // send once immediately
  }

  /// Call after user gesture (e.g. tap) to unlock agent audio in Chrome. Use when [audioPlaybackFailed] is true.
  Future<void> playbackAudio() async {
    final room = _room;
    if (room == null) return;
    try {
      await room.startAudio();
      _audioPlaybackFailed = false;
      notifyListeners();
    } catch (e) {
      debugPrint('VoiceService playbackAudio: $e');
    }
  }

  void _publishGps() {
    if (!_navigationEnabled) return;
    final room = _room;
    if (room == null) return;
    if (_lat == null || _lng == null) return;

    String payloadStr = '{"lat":$_lat,"lng":$_lng}';
    if (_heading != null) {
      payloadStr = '{"lat":$_lat,"lng":$_lng,"heading":$_heading}';
    }
    _publishDataSafe(utf8.encode(payloadStr), _gpsTopic);
  }

  /// Publish current GPS + heading immediately (e.g. when compass updates).
  /// Ensures nav gets fresh heading when user turns. No-op if navigation disabled.
  void publishGpsNow() {
    if (_navigationEnabled && _room != null && _lat != null && _lng != null) {
      _publishGps();
    }
  }

  /// Disconnect from the voice agent. Memory is kept; next connect will restore context.
  Future<void> disconnect() async {
    final room = _room;
    if (room == null) return;
    _disconnecting = true;
    _gpsTimer?.cancel();
    _gpsTimer = null;
    _roomListener?.dispose();
    _roomListener = null;
    _room = null;
    _audioPlaybackFailed = false;
    try {
      await room.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      _disconnecting = false;
    }
    notifyListeners();
  }

  /// Toggle: if connected, disconnect; otherwise connect.
  Future<void> toggle() async {
    if (isConnected) {
      await disconnect();
    } else {
      await connect();
    }
  }
}
