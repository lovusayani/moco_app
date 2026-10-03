// Vercel Queues consumer: billing tick (one minute of one call).
// Triggered by the moco-tick topic (see vercel.json). Not reachable from
// the internet; only Vercel Queues can invoke it. The handler is the same one
// local development runs inline — see src/jobs/handlers.js.
import { handleCallback } from '@vercel/queue';
import { attachDatabasePool } from '@vercel/functions';
import handlers from '../../src/jobs/handlers.js';
import jobs from '../../src/jobs/index.js';
import db from '../../src/config/db.js';

attachDatabasePool(db.pool);

export const POST = handleCallback((message) => handlers.handle(jobs.TOPICS.TICK, message), {
  // At-least-once delivery: retry a failure after 5s, and give up after
  // 8 deliveries rather than retrying stale work for hours.
  retry: (error, metadata) => {
    console.error('[moco-tick] delivery', metadata.deliveryCount, 'failed:', error?.message);
    return metadata.deliveryCount >= 8 ? { acknowledge: true } : { afterSeconds: 5 };
  },
});
