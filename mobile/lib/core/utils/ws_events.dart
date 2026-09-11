/// Socket.IO event names, mirroring WS_EVENTS in the backend's constants.js.
///
/// Kept as one list so an event name is never typed as a literal at a call site
/// and cannot drift from the server unnoticed.
class WsEvents {
  const WsEvents._();

  static const presence = 'listener:presence';
  static const incomingCall = 'call:incoming';
  static const callAccepted = 'call:accepted';
  static const tick = 'call:tick';
  static const lowBalance = 'call:low_balance';
  static const forcedEnd = 'call:forced_end';
  static const callEnded = 'call:ended';
  static const chatMessage = 'chat:message';
  static const chatReaction = 'chat:reaction';
}
