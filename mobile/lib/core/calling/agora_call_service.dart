import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../config/env.dart';
import '../../shared/models/call.dart';

/// Connection state the UI cares about. A narrower set than Agora's own
/// [ConnectionStateType] — the call screens only need to distinguish these.
enum RtcConnectionStatus { disconnected, connecting, connected, reconnecting, failed }

/// Outcome of the mic/camera permission check done before joining. A call
/// never joins Agora without [granted] — there is no "connect anyway" path.
enum CallPermissionStatus {
  granted,
  microphoneDenied,
  microphonePermanentlyDenied,
  cameraDenied,
  cameraPermanentlyDenied,
}

extension CallPermissionStatusX on CallPermissionStatus {
  bool get isPermanentlyDenied =>
      this == CallPermissionStatus.microphonePermanentlyDenied ||
      this == CallPermissionStatus.cameraPermanentlyDenied;
}

/// Thin wrapper around the Agora RTC engine.
///
/// This is the ONLY place `agora_rtc_engine` is imported outside this file's
/// own concerns — screens and the call controller talk to this service, never
/// to the engine directly, so the SDK can be swapped or mocked in tests.
///
/// Every join uses a server-issued channel/token/uid ([AgoraCredentials]).
/// Nothing here ever generates a token. A null [AgoraCredentials.token] means
/// the backend has no Agora app certificate configured (local dev); the
/// engine still attempts to join, matching how Agora treats a missing token
/// in a project with App ID-only authentication, but callers of this service
/// should surface [AgoraCredentials.isConfigured] to the user rather than
/// claim a real connection is guaranteed.
class AgoraCallService {
  AgoraCallService();

  RtcEngine? _engine;
  bool _videoEnabled = false;
  bool _disposed = false;

  final ValueNotifier<RtcConnectionStatus> connectionStatus = ValueNotifier(
    RtcConnectionStatus.disconnected,
  );
  final ValueNotifier<bool> remoteJoined = ValueNotifier(false);
  final ValueNotifier<bool> muted = ValueNotifier(false);
  final ValueNotifier<bool> speakerOn = ValueNotifier(true);
  final ValueNotifier<bool> localVideoEnabled = ValueNotifier(false);
  final ValueNotifier<int?> remoteUid = ValueNotifier(null);
  final ValueNotifier<CallPermissionStatus?> permissionStatus = ValueNotifier(
    null,
  );

  /// Called when Agora reports the remote party left the channel (as opposed
  /// to the server ending the call) — used only for UI ("reconnecting…"),
  /// never to end the call. Only the server ends a call.
  VoidCallback? onRemoteLeft;

  bool get isVideoCall => _videoEnabled;

  /// Joins [credentials]'s channel for [type]. Safe to call once per call;
  /// [leave] must be called (directly or via [dispose]) before joining again.
  Future<void> join({
    required AgoraCredentials credentials,
    required CallType type,
  }) async {
    if (!credentials.isConfigured) {
      // Nothing to join — surfaced to the UI via connectionStatus staying
      // disconnected/failed rather than a thrown exception, since this is an
      // expected development-mode condition, not a call bug.
      connectionStatus.value = RtcConnectionStatus.failed;
      return;
    }

    _videoEnabled = type == CallType.video;

    final permission = await _ensurePermissions(video: _videoEnabled);
    permissionStatus.value = permission;
    if (permission != CallPermissionStatus.granted) {
      // Never join with media the user has not actually granted — a denied
      // mic must not silently become a one-way or fake-connected call.
      connectionStatus.value = RtcConnectionStatus.failed;
      return;
    }

    connectionStatus.value = RtcConnectionStatus.connecting;

    final engine = createAgoraRtcEngine();
    _engine = engine;

    await engine.initialize(RtcEngineContext(appId: Env.agoraAppId));

    engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (connection, elapsed) {
          if (_disposed) return;
          connectionStatus.value = RtcConnectionStatus.connected;
        },
        onUserJoined: (connection, uid, elapsed) {
          if (_disposed) return;
          remoteUid.value = uid;
          remoteJoined.value = true;
        },
        onUserOffline: (connection, uid, reason) {
          if (_disposed) return;
          remoteJoined.value = false;
          remoteUid.value = null;
          onRemoteLeft?.call();
        },
        onConnectionStateChanged: (connection, state, reason) {
          if (_disposed) return;
          connectionStatus.value = switch (state) {
            ConnectionStateType.connectionStateConnecting =>
              RtcConnectionStatus.connecting,
            ConnectionStateType.connectionStateConnected =>
              RtcConnectionStatus.connected,
            ConnectionStateType.connectionStateReconnecting =>
              RtcConnectionStatus.reconnecting,
            ConnectionStateType.connectionStateFailed =>
              RtcConnectionStatus.failed,
            ConnectionStateType.connectionStateDisconnected =>
              RtcConnectionStatus.disconnected,
          };
        },
        onError: (err, msg) {
          if (_disposed) return;
          if (Env.enableHttpLogging) debugPrint('agora error: $err $msg');
        },
      ),
    );

    await engine.enableAudio();
    if (_videoEnabled) {
      await engine.enableVideo();
      await engine.startPreview();
      localVideoEnabled.value = true;
    } else {
      // Never initialise the camera for an audio call.
      await engine.disableVideo();
    }

    await engine.setDefaultAudioRouteToSpeakerphone(true);
    speakerOn.value = true;

    await engine.joinChannel(
      token: credentials.token ?? '',
      channelId: credentials.channel,
      uid: credentials.uid,
      options: ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        channelProfile: ChannelProfileType.channelProfileCommunication,
        publishCameraTrack: _videoEnabled,
        publishMicrophoneTrack: true,
        autoSubscribeAudio: true,
        autoSubscribeVideo: _videoEnabled,
      ),
    );
  }

  Future<void> toggleMute() async {
    final next = !muted.value;
    await _engine?.muteLocalAudioStream(next);
    muted.value = next;
  }

  Future<void> setSpeaker(bool on) async {
    await _engine?.setEnableSpeakerphone(on);
    speakerOn.value = on;
  }

  Future<void> toggleLocalVideo() async {
    if (!_videoEnabled) return;
    final next = !localVideoEnabled.value;
    await _engine?.enableLocalVideo(next);
    localVideoEnabled.value = next;
  }

  Future<void> switchCamera() async {
    if (!_videoEnabled) return;
    await _engine?.switchCamera();
  }

  RtcEngine? get engineOrNull => _engine;

  Future<void> leave() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.leaveChannel();
      await engine.release();
    } catch (_) {
      // Best-effort: the channel is also kicked server-side on a forced end
      // (agora.js::terminateChannel), so a local leave failure cannot strand
      // the call in a billed-but-connected state.
    } finally {
      _engine = null;
      connectionStatus.value = RtcConnectionStatus.disconnected;
      remoteJoined.value = false;
      remoteUid.value = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await leave();
    connectionStatus.dispose();
    remoteJoined.dispose();
    muted.dispose();
    speakerOn.dispose();
    localVideoEnabled.dispose();
    remoteUid.dispose();
    permissionStatus.dispose();
  }

  /// Requests only the permissions this call actually needs — the microphone
  /// always, the camera only for a video call, matching Phase 2 §10.
  Future<CallPermissionStatus> _ensurePermissions({required bool video}) async {
    final mic = await _ensure(ph.Permission.microphone);
    if (mic == _Grant.permanentlyDenied) {
      return CallPermissionStatus.microphonePermanentlyDenied;
    }
    if (mic == _Grant.denied) return CallPermissionStatus.microphoneDenied;

    if (!video) return CallPermissionStatus.granted;

    final camera = await _ensure(ph.Permission.camera);
    if (camera == _Grant.permanentlyDenied) {
      return CallPermissionStatus.cameraPermanentlyDenied;
    }
    if (camera == _Grant.denied) return CallPermissionStatus.cameraDenied;

    return CallPermissionStatus.granted;
  }

  Future<_Grant> _ensure(ph.Permission permission) async {
    final status = await permission.status;
    if (status.isGranted) return _Grant.granted;
    if (status.isPermanentlyDenied) return _Grant.permanentlyDenied;

    final requested = await permission.request();
    if (requested.isGranted) return _Grant.granted;
    if (requested.isPermanentlyDenied) return _Grant.permanentlyDenied;
    return _Grant.denied;
  }

  /// Routes to the OS app-settings screen — the only recovery from a
  /// permanently-denied permission per Phase 2 §10.
  Future<void> openAppSettings() => ph.openAppSettings();
}

enum _Grant { granted, denied, permanentlyDenied }
