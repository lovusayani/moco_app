// Vercel Queues consumer: stale-call sweep.
// Triggered by the moco-sweep topic (see vercel.json). Not reachable from
// the internet; only Vercel Queues can invoke it. The handler is the same one
// local development runs inline — see src/jobs/handlers.js.
import { handleCallback } from '@vercel/queue';
import { attachDatabasePool } from '@vercel/functions';
import handlers from '../../src/jobs/handlers.js';
import jobs from '../../src/jobs/index.js';
import db from '../../src/config/db.js';

attachDatabasePool(db.pool);

export const POST = handleCallback((message) => handlers.handle(jobs.TOPICS.SWEEP, message), {
  // At-least-once delivery: retry a failure after 10s, and give up after
  // 5 deliveries rather than retrying stale work for hours.
  retry: (error, metadata) => {
    console.error('[moco-sweep] delivery', metadata.deliveryCount, 'failed:', error?.message);
    return metadata.deliveryCount >= 5 ? { acknowledge: true } : { afterSeconds: 10 };
  },
});
