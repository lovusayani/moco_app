// Vercel Cron (daily, see vercel.json): restarts the stale-call sweep chain.
//
// The sweep normally re-schedules itself every minute while calls are live
// (src/workers/sweep.worker.js) and is re-armed by every call start and tick.
// This is the backstop if a chain was ever lost. Daily is the most Hobby
// allows, and the per-minute chain does not depend on it.
import jobs from '../../src/jobs/index.js';

export async function GET(request) {
  const secret = process.env.CRON_SECRET;
  if (!secret || request.headers.get('authorization') !== `Bearer ${secret}`) {
    return new Response('Unauthorized', { status: 401 });
  }
  await jobs.ensureSweep(0);
  return Response.json({ ok: true });
}
