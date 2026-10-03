// Vercel Function: the whole API (Express + Socket.IO) behind
// https://api.lovcamx.online. vercel.json rewrites every path that is not a
// file or another function here; Express sees the original URL.
//
// Exporting the http.Server (not just the Express app) is what lets Vercel
// hand WebSocket upgrades to Socket.IO. A socket stays on the instance that
// accepted it until the function's maxDuration, then the client reconnects.
import { attachDatabasePool } from '@vercel/functions';
import http from '../src/http.js';
import db from '../src/config/db.js';

// Lets Fluid compute release idle Postgres connections before it suspends an
// instance, so a quiet instance does not hold pooler slots.
attachDatabasePool(db.pool);

const { server } = http.buildServer();

export default server;
