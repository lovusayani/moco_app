// Vercel Function: lovcamx.online/api/* -> https://api.lovcamx.online/api/*
// (vercel.json rewrites /api/:path* here). See api/_lib/moco_proxy.mjs.
import { createProxy } from './_lib/moco_proxy.mjs';

// Public: the backend's address is no secret (the Android app ships it too).
const BACKEND_ORIGIN = 'https://api.lovcamx.online';

const proxy = createProxy({ origin: BACKEND_ORIGIN, allow: /^[^/]/ });

export default { fetch: proxy };
