// Vercel Queues consumer: Moco Live sync / daily cleanup.
// Triggered by the moco-live topic (see vercel.json). Not reachable from
// the internet; only Vercel Queues can invoke it. The handler is the same one
// local development runs inline — see src/jobs/handlers.js.
import { handleCallback } from '@vercel/queue';
import { attachDatabasePool } from '@vercel/functions';
import handlers from '../../src/jobs/handlers.js';
import jobs from '../../src/jobs/index.js';
import db from '../../src/config/db.js';

attachDatabasePool(db.pool);

export const POST = handleCallback((message) => handlers.handle(jobs.TOPICS.LIVE, message), {
  // Provider failures do not throw (the next sync retries naturally); this
  // only covers a database failure. A sync older than a minute is useless.
  retry: (error, metadata) => {
    console.error('[moco-live] delivery', metadata.deliveryCount, 'failed:', error?.message);
    return metadata.deliveryCount >= 2 ? { acknowledge: true } : { afterSeconds: 10 };
  },
});
