// Vercel Function: admin.lovcamx.online/api/{auth,admin}/* ->
// https://api.lovcamx.online/api/{auth,admin}/* (vercel.json rewrites only
// those two prefixes here). See api/_lib/moco_proxy.mjs.
import { createProxy } from './_lib/moco_proxy.mjs';

// Public: the backend's address is no secret (the Android app ships it too).
const BACKEND_ORIGIN = 'https://api.lovcamx.online';

// Re-checked here, not only in vercel.json: the console needs OTP sign-in and
// the admin API, nothing else.
const proxy = createProxy({ origin: BACKEND_ORIGIN, allow: /^(auth|admin)\/./ });

export default { fetch: proxy };
