import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../config/env.dart';

enum SocketStatus { disconnected, connecting, connected }

/// Socket.IO connection to the Moco backend.
///
/// Establishes and supervises the connection. The server emits
/// `listener:presence` whenever a listener's online/busy state changes
/// (src/realtime/presence.js via the `moco:events` Redis bridge), broadcast to
/// every socket's `discovery` room, plus the call lifecycle events (`call:tick`,
/// `call:low_balance`, `call:forced_end`, `call:incoming`, `call:accepted`,
/// `call:ended`) delivered to a caller/listener's own `user:<id>` room, and
/// `chat:message`. [on] lets a screen or controller subscribe to any of these
/// without this class knowing about call/chat/discovery concerns itself.
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

  /// Emits a client→server event, e.g. `heartbeat` with `{ callId }` during an
  /// active call. A no-op while disconnected — the server-side sweeper is the
  /// backstop for a call that never gets a heartbeat.
  void emit(String event, [dynamic data]) {
    _socket?.emit(event, data);
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
