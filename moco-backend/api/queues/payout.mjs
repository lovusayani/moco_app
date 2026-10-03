// Vercel Queues consumer: admin-approved payout.
// Triggered by the moco-payout topic (see vercel.json). Not reachable from
// the internet; only Vercel Queues can invoke it. The handler is the same one
// local development runs inline — see src/jobs/handlers.js.
import { handleCallback } from '@vercel/queue';
import { attachDatabasePool } from '@vercel/functions';
import handlers from '../../src/jobs/handlers.js';
import jobs from '../../src/jobs/index.js';
import db from '../../src/config/db.js';

attachDatabasePool(db.pool);

export const POST = handleCallback((message) => handlers.handle(jobs.TOPICS.PAYOUT, message), {
  // At-least-once delivery: retry a failure after 60s, and give up after
  // 10 deliveries rather than retrying stale work for hours.
  retry: (error, metadata) => {
    console.error('[moco-payout] delivery', metadata.deliveryCount, 'failed:', error?.message);
    return metadata.deliveryCount >= 10 ? { acknowledge: true } : { afterSeconds: 60 };
  },
});
