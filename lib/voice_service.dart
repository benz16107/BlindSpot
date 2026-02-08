import 'dart:async';
import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import 'config.dart';

/// Toggle voice agent on/off. When on: connects to LiveKit, publishes mic + GPS.
/// When off: disconnects; memory is kept on the server (Backboard) and restored on next connect.
class VoiceService extends ChangeNotifier {
  Room? _room;
  Timer? _gpsTimer;
  double? _lat;
  double? _lng;
  double? _heading; // compass heading 0-360 (0 = north), for agent
  EventsListener<RoomEvent>? _roomListener;

  static const String _gpsTopic = 'gps';
  static const String _obstacleTopic = 'obstacle';
  static const Duration _gpsInterval = Duration(seconds: 3);

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

  /// Generate a LiveKit JWT in-app (no token server). Requires [liveKitUrl], [liveKitApiKey], [liveKitApiSecret] in config.
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
    } else {
      final tokenServerUrl = (tokenUrlOverride ?? tokenUrl).trim();
      if (tokenServerUrl.isEmpty) {
        throw Exception('Token server URL not set. Set it in the app (e.g. http://YOUR_COMPUTER_IP:8765/token).');
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final identity = 'mobile-user-$now';
      final roomName = 'voice-nav-$now';
      final uri = Uri.parse(tokenServerUrl).replace(
        queryParameters: {'identity': identity, 'room': roomName},
      );
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
      _startGpsPublishing();

      try {
        await room.startAudio();
      } catch (e) {
        debugPrint('VoiceService startAudio: $e');
      }

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
      });
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
    final room = _room;
    if (room == null) return;
    if (_lat == null || _lng == null) return;

    try {
      String payloadStr = '{"lat":$_lat,"lng":$_lng}';
      if (_heading != null) payloadStr = '{"lat":$_lat,"lng":$_lng,"heading":$_heading}';
      room.localParticipant?.publishData(utf8.encode(payloadStr), topic: _gpsTopic);
    } catch (e) {
      debugPrint('VoiceService GPS publish: $e');
    }
  }

  /// Notify the voice agent that obstacle detection found something (agent can warn user by voice).
  void publishObstacleDetected(String description) {
    final room = _room;
    if (room == null) return;
    try {
      final payload = jsonEncode({'obstacle': description, 'ts': DateTime.now().millisecondsSinceEpoch});
      room.localParticipant?.publishData(utf8.encode(payload), topic: _obstacleTopic);
    } catch (e) {
      debugPrint('VoiceService obstacle publish: $e');
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
