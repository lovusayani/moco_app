import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config/env.dart';

enum SocketStatus { disconnected, connecting, connected }

/// Socket.IO connection to the Moco backend.
///
/// Phase 1 establishes and supervises the connection but subscribes to no
/// events yet. The backend declares `listener:presence` in its constants but
/// never emits it (verified in src/realtime/), so discovery presence still
/// comes from the HTTP response — there is no live presence stream to consume.
/// The event surface that IS emitted (call:tick, call:low_balance,
/// call:forced_end, call:incoming, call:ended, chat:message) belongs to later
/// phases, and [on] is here so they can be wired without touching this class.
class SocketService {
  SocketService();

  io.Socket? _socket;

  final ValueNotifier<SocketStatus> status = ValueNotifier(
    SocketStatus.disconnected,
  );

  /// Guards against a second connect while one is already open — two sockets
  /// would double every future call event.
  bool get isActive => _socket != null;

  void connect(String token) {
    if (_socket != null) return;

    status.value = SocketStatus.connecting;

    // The server reads the JWT from handshake.auth.token (socket.server.js).
    final socket = io.io(
      Env.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .setAuth({'token': token})
          .enableReconnection()
          .setReconnectionAttempts(0) // retry indefinitely
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(15000) // exponential backoff, capped
          .build(),
    );

    socket.onConnect((_) {
      status.value = SocketStatus.connected;
      if (Env.enableHttpLogging) debugPrint('socket connected');
    });
    socket.onDisconnect((_) {
      status.value = SocketStatus.disconnected;
      if (Env.enableHttpLogging) debugPrint('socket disconnected');
    });
    socket.onReconnectAttempt((_) => status.value = SocketStatus.connecting);
    socket.onConnectError((err) {
      status.value = SocketStatus.disconnected;
      // Never log the error object itself — the handshake carries the token.
      if (Env.enableHttpLogging) debugPrint('socket connect error');
    });

    _socket = socket;
    socket.connect();
  }

  /// Subscribes to a server event. Returns a disposer, so a screen can detach
  /// its listener on dispose and not leak across navigations.
  VoidCallback on(String event, void Function(dynamic data) handler) {
    final socket = _socket;
    if (socket == null) return () {};
    socket.on(event, handler);
    return () => socket.off(event, handler);
  }

  void disconnect() {
    _socket
      ?..clearListeners()
      ..dispose();
    _socket = null;
    status.value = SocketStatus.disconnected;
  }

  void dispose() {
    disconnect();
    status.dispose();
  }
}
