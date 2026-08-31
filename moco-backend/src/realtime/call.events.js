'use strict';

const { redis, createQueueConnection } = require('../config/redis');
const socketServer = require('./socket.server');
const { WS_EVENTS } = require('../utils/constants');
const logger = require('../utils/logger');

/**
 * Bridges worker processes to connected sockets.
 *
 * The tick worker runs in its own PM2 process and holds no sockets, so it
 * cannot emit directly. It publishes to a Redis channel; the API process (which
 * does hold the sockets) subscribes and forwards. This also means the API can
 * be scaled to several instances and every one of them will deliver to whoever
 * it happens to be holding.
 */

const CHANNEL = 'moco:events';

/** Publishes an event for delivery to a user, from any process. */
async function publishToUser(userId, event, payload) {
  await redis.publish(CHANNEL, JSON.stringify({ userId: String(userId), event, payload }));
}

/** Subscribes this process's socket server to the event channel. */
function startSubscriber() {
  // A connection in subscriber mode cannot run normal commands, so this needs
  // its own connection rather than sharing the main one.
  const subscriber = createQueueConnection();

  subscriber.subscribe(CHANNEL, (err) => {
    if (err) logger.error({ err }, 'failed to subscribe to event channel');
    else logger.info('subscribed to realtime event channel');
  });

  subscriber.on('message', (channel, raw) => {
    if (channel !== CHANNEL) return;
    try {
      const { userId, event, payload } = JSON.parse(raw);
      socketServer.emitToUser(userId, event, payload);
    } catch (err) {
      logger.error({ err, raw }, 'bad realtime event payload');
    }
  });

  return subscriber;
}

const tick = (userId, payload) => publishToUser(userId, WS_EVENTS.TICK, payload);
const lowBalance = (userId, payload) => publishToUser(userId, WS_EVENTS.LOW_BALANCE, payload);
const forcedEnd = (userId, payload) => publishToUser(userId, WS_EVENTS.FORCED_END, payload);
const incomingCall = (userId, payload) => publishToUser(userId, WS_EVENTS.INCOMING_CALL, payload);
const callAccepted = (userId, payload) => publishToUser(userId, WS_EVENTS.CALL_ACCEPTED, payload);
const callEnded = (userId, payload) => publishToUser(userId, WS_EVENTS.CALL_ENDED, payload);
const chatMessage = (userId, payload) => publishToUser(userId, WS_EVENTS.CHAT_MESSAGE, payload);

module.exports = {
  CHANNEL,
  publishToUser,
  startSubscriber,
  tick,
  lowBalance,
  forcedEnd,
  incomingCall,
  callAccepted,
  callEnded,
  chatMessage,
};
