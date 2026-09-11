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

/**
 * Broadcast room every connected client joins.
 *
 * Presence is the one event with no single recipient — anyone looking at
 * discovery wants it — so it goes to a shared room rather than a user room.
 */
const DISCOVERY_ROOM = 'discovery';

/** Publishes an event for delivery to a user, from any process. */
async function publishToUser(userId, event, payload) {
  await redis.publish(CHANNEL, JSON.stringify({ userId: String(userId), event, payload }));
}

/**
 * Publishes an event to every connected client, from any process.
 *
 * Uses the same Redis channel as user-targeted events, distinguished by
 * `broadcast: true`, so workers keep exactly one publish path.
 */
async function publishBroadcast(event, payload) {
  await redis.publish(CHANNEL, JSON.stringify({ broadcast: true, event, payload }));
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
      const { userId, event, payload, broadcast } = JSON.parse(raw);
      if (broadcast) {
        socketServer.emitToRoom(DISCOVERY_ROOM, event, payload);
      } else {
        socketServer.emitToUser(userId, event, payload);
      }
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

/** A reaction was added, changed, or removed. `emoji: null` means removed. */
const chatReaction = (userId, payload) => publishToUser(userId, WS_EVENTS.CHAT_REACTION, payload);

/**
 * A listener came online or went offline.
 *
 * Broadcast so open discovery grids update in place instead of waiting for the
 * user to pull-to-refresh.
 */
const listenerPresence = ({ listenerId, isOnline, isBusy = false }) =>
  publishBroadcast(WS_EVENTS.PRESENCE, {
    listenerId: Number(listenerId),
    isOnline,
    isBusy,
  });

module.exports = {
  CHANNEL,
  DISCOVERY_ROOM,
  publishToUser,
  publishBroadcast,
  startSubscriber,
  tick,
  lowBalance,
  forcedEnd,
  incomingCall,
  callAccepted,
  callEnded,
  chatMessage,
  chatReaction,
  listenerPresence,
};
