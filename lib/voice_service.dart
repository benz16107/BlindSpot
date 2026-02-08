import 'dart:async';
import 'dart:convert';

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
  EventsListener<RoomEvent>? _roomListener;

  static const String _gpsTopic = 'gps';
  static const Duration _gpsInterval = Duration(seconds: 3);

  bool get isConnected => _room != null;

  /// True when Chrome (or browser) blocked playback; user must tap "Play agent audio" to hear.
  bool get audioPlaybackFailed => _audioPlaybackFailed;
  bool _audioPlaybackFailed = false;

  /// Call whenever position updates so we can publish when connected.
  void updateGps(double lat, double lng) {
    _lat = lat;
    _lng = lng;
  }

  /// Connect to the voice agent (publish mic; start sending GPS). Memory from previous sessions is preserved on the server.
  Future<void> connect() async {
    if (_room != null) return;

    try {
      final uri = Uri.parse(tokenUrl);
      final resp = await http.get(uri);
      if (resp.statusCode != 200) {
        throw Exception('Token failed: ${resp.statusCode} ${resp.body}');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = body['token'] as String?;
      final url = body['url'] as String?;
      if (token == null || token.isEmpty || url == null || url.isEmpty) {
        throw Exception('Invalid token response: missing token or url');
      }

      final room = Room();
      _setUpRoomListeners(room);
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

      // Unlock web audio (Chrome requires user gesture; we're in the button tap here)
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
      ..on<TrackSubscribedEvent>((event) async {
        // When agent's audio track arrives, try to start playback (Chrome often blocks until user gesture)
        if (event.track.kind == TrackType.AUDIO) {
          try {
            await event.track.enable();
            await room.startAudio();
            // Give Chrome a moment to attach the element, then try again (helps if first play() was blocked)
            await Future<void>.delayed(const Duration(milliseconds: 300));
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
      final payload = utf8.encode('{"lat":$_lat,"lng":$_lng}');
      room.localParticipant?.publishData(payload, topic: _gpsTopic);
    } catch (e) {
      debugPrint('VoiceService GPS publish: $e');
    }
  }

  /// Disconnect from the voice agent. Memory is kept; next connect will restore context.
  Future<void> disconnect() async {
    _gpsTimer?.cancel();
    _gpsTimer = null;
    _roomListener?.dispose();
    _roomListener = null;
    _audioPlaybackFailed = false;
    final room = _room;
    _room = null;
    if (room != null) {
      await room.disconnect();
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
