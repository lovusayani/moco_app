'use strict';

const http = require('http');
const { createApp } = require('./app');
const socketServer = require('./realtime/socket.server');
const callEvents = require('./realtime/call.events');

/**
 * Builds the API: Express plus Socket.IO on one HTTP server.
 *
 * Used by api/index.mjs on Vercel (which serves the exported server as a
 * Vercel Function, WebSocket upgrades included) and by src/server.js for
 * local development (which listens on PORT).
 *
 * Every instance subscribes to the Redis event channel: a socket lives on
 * whichever instance accepted it, and events from queue consumers and other
 * instances arrive through Redis (see realtime/call.events.js).
 */
function buildServer() {
  const app = createApp();
  const server = http.createServer(app);
  socketServer.init(server);
  const subscriber = callEvents.startSubscriber();
  return { app, server, subscriber };
}

module.exports = { buildServer };
