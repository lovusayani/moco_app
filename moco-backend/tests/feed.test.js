'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
const queues = require('../src/workers/queues');
const { resetDb, createUser, createPost } = require('./helpers');
const { signToken } = require('../src/middleware/auth');
const { query } = require('../src/config/db');

/**
 * Feed HTTP tests.
 *
 * These run WITHOUT Supabase Storage configured, which is deliberate — it is
 * the state the backend ships in until buckets exist, and every authorization
 * rule below must hold in it. Anything that genuinely needs a stored object
 * (publishing a post end to end) is covered by `npm run smoke` against a
 * configured project instead, because faking the bucket here would test the
 * fake rather than the rule.
 */

let server;
let baseUrl;

test.before(async () => {
  await resetDb();
  server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

test.after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await queues.closeAll();
  await db.close();
  await redisConfig.close();
});

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
}

test('the feed requires authentication', async () => {
  await resetDb();
  const anonymous = await call('GET', '/api/feed');
  assert.equal(anonymous.status, 401);
});

test('the feed returns posts newest first with author info', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser({ listener: true });

  const older = await createPost({ author, caption: 'first' });
  const newer = await createPost({ author, mediaType: 'video', caption: 'second' });

  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  assert.equal(feed.status, 200);
  assert.deepEqual(
    feed.body.posts.map((p) => p.id),
    [newer.id, older.id],
    'newest post must come first',
  );

  const [first] = feed.body.posts;
  assert.equal(first.mediaType, 'video');
  assert.equal(first.caption, 'second');
  assert.equal(first.author.id, author.id);
  assert.equal(first.author.isListener, true);
  assert.equal(first.author.verified, true);
  // Storage is not configured in this environment, so a signed URL cannot be
  // minted. The post is still served — the client shows a media error state
  // rather than the whole feed failing.
  assert.equal(first.mediaUrl, null);
});

test('an empty feed is a 200 with an empty list, not an error', async () => {
  await resetDb();
  const viewer = await createUser();

  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  assert.equal(feed.status, 200);
  assert.deepEqual(feed.body.posts, []);
  assert.equal(feed.body.nextCursor, null);
});

test('cursor pagination walks the whole feed without skipping or repeating', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();

  const created = [];
  for (let i = 0; i < 5; i += 1) {
    created.push(await createPost({ author, caption: `post ${i}` }));
  }
  const expected = created.map((p) => p.id).reverse();

  const page1 = await call('GET', '/api/feed?limit=2', { token: signToken(viewer) });
  assert.equal(page1.status, 200);
  assert.deepEqual(page1.body.posts.map((p) => p.id), expected.slice(0, 2));
  assert.equal(page1.body.nextCursor, expected[1]);

  const page2 = await call(`GET`, `/api/feed?limit=2&cursor=${page1.body.nextCursor}`, {
    token: signToken(viewer),
  });
  assert.deepEqual(page2.body.posts.map((p) => p.id), expected.slice(2, 4));

  const page3 = await call('GET', `/api/feed?limit=2&cursor=${page2.body.nextCursor}`, {
    token: signToken(viewer),
  });
  assert.deepEqual(page3.body.posts.map((p) => p.id), expected.slice(4));
  // A short page is the end of the feed.
  assert.equal(page3.body.nextCursor, null);
});

test('a malformed cursor is rejected rather than silently ignored', async () => {
  await resetDb();
  const viewer = await createUser();

  const bad = await call('GET', '/api/feed?cursor=notanumber', { token: signToken(viewer) });
  assert.equal(bad.status, 400);
});

test('the feed hides posts from users blocked in either direction', async () => {
  await resetDb();
  const viewer = await createUser();
  const blockedByViewer = await createUser();
  const blockerOfViewer = await createUser();
  const unrelated = await createUser();

  await createPost({ author: blockedByViewer });
  await createPost({ author: blockerOfViewer });
  const visible = await createPost({ author: unrelated });

  await query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [
    viewer.id,
    blockedByViewer.id,
  ]);
  await query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [
    blockerOfViewer.id,
    viewer.id,
  ]);

  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  assert.deepEqual(
    feed.body.posts.map((p) => p.id),
    [visible.id],
    'a block in either direction must hide the post',
  );
});

test('the feed hides removed posts and suspended authors', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();
  const suspended = await createUser();

  await createPost({ author, status: 'removed' });
  await createPost({ author: suspended });
  const visible = await createPost({ author });

  await query(`UPDATE users SET status = 'suspended' WHERE id = $1`, [suspended.id]);

  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  assert.deepEqual(feed.body.posts.map((p) => p.id), [visible.id]);
});

test('a non-listener author is marked so the client does not link to a missing screen', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();
  await createPost({ author });

  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  assert.equal(feed.body.posts[0].author.isListener, false);
  assert.equal(feed.body.posts[0].author.verified, null);
});

test('posting media under another user\'s path is forbidden regardless of storage config', async () => {
  await resetDb();
  const user = await createUser();
  const other = await createUser();

  const forbidden = await call('POST', '/api/feed', {
    token: signToken(user),
    body: { mediaPath: `${other.id}/someone_elses.jpg` },
  });
  // Must be 403, NOT storage_not_configured: an unauthorized path is refused
  // whether or not storage happens to be up. Config state cannot widen access.
  assert.equal(forbidden.status, 403);
});

test('an unsupported media extension cannot be posted', async () => {
  await resetDb();
  const user = await createUser();

  const bad = await call('POST', '/api/feed', {
    token: signToken(user),
    body: { mediaPath: `${user.id}/payload.exe` },
  });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, 'unsupported_media');
});

test('an over-long caption is rejected', async () => {
  await resetDb();
  const user = await createUser();

  const long = await call('POST', '/api/feed', {
    token: signToken(user),
    body: { mediaPath: `${user.id}/ok.jpg`, caption: 'x'.repeat(501) },
  });
  assert.equal(long.status, 400);
});

test('publishing reports storage honestly when it is not configured', async () => {
  await resetDb();
  const user = await createUser();

  const upload = await call('POST', '/api/feed/media/upload-url', {
    token: signToken(user),
    body: { mimeType: 'image/png' },
  });
  assert.equal(upload.status, 400);
  assert.equal(upload.body.error.code, 'storage_not_configured');

  // A path this user legitimately owns still cannot be published without
  // storage, because the object's existence and size cannot be verified.
  const create = await call('POST', '/api/feed', {
    token: signToken(user),
    body: { mediaPath: `${user.id}/mine.jpg` },
  });
  assert.equal(create.status, 400);
  assert.equal(create.body.error.code, 'storage_not_configured');
});

test('the upload endpoint refuses a disallowed MIME type', async () => {
  await resetDb();
  const user = await createUser();

  const bad = await call('POST', '/api/feed/media/upload-url', {
    token: signToken(user),
    body: { mimeType: 'application/x-msdownload' },
  });
  assert.equal(bad.status, 400);
});

test('an author can soft-delete their own post, and it leaves the feed', async () => {
  await resetDb();
  const author = await createUser();
  const post = await createPost({ author });

  const deleted = await call('DELETE', `/api/feed/${post.id}`, { token: signToken(author) });
  assert.equal(deleted.status, 200);

  const feed = await call('GET', '/api/feed', { token: signToken(author) });
  assert.deepEqual(feed.body.posts, []);

  // Soft delete: the row survives so a report against it still resolves.
  const { rows } = await query('SELECT status FROM posts WHERE id = $1', [post.id]);
  assert.equal(rows[0].status, 'removed');
});

test('deleting an already-deleted own post is idempotent', async () => {
  await resetDb();
  const author = await createUser();
  const post = await createPost({ author });

  assert.equal((await call('DELETE', `/api/feed/${post.id}`, { token: signToken(author) })).status, 200);
  assert.equal((await call('DELETE', `/api/feed/${post.id}`, { token: signToken(author) })).status, 200);
});

test('another user cannot delete a post, and cannot confirm it exists', async () => {
  await resetDb();
  const author = await createUser();
  const stranger = await createUser();
  const post = await createPost({ author });

  const attempt = await call('DELETE', `/api/feed/${post.id}`, { token: signToken(stranger) });
  // 404 rather than 403 on purpose: a 403 would confirm the id is real.
  assert.equal(attempt.status, 404);
  assert.equal(
    (await call('DELETE', '/api/feed/999999', { token: signToken(stranger) })).status,
    404,
    'a real but foreign post and a non-existent one must be indistinguishable',
  );

  const { rows } = await query('SELECT status FROM posts WHERE id = $1', [post.id]);
  assert.equal(rows[0].status, 'active', 'the post must be untouched');
});

test('the same media path cannot back two posts', async () => {
  await resetDb();
  const author = await createUser();
  const post = await createPost({ author });

  await assert.rejects(
    () =>
      query(
        `INSERT INTO posts (author_user_id, media_type, media_path) VALUES ($1, $2, $3)`,
        [author.id, 'image', post.media_path],
      ),
    /posts_media_path_unique/,
    'UNIQUE (media_path) is what makes a retried publish safe',
  );
});

test('a blank caption cannot be stored as an empty string', async () => {
  await resetDb();
  const author = await createUser();

  await assert.rejects(
    () =>
      query(
        `INSERT INTO posts (author_user_id, media_type, media_path, caption)
         VALUES ($1, 'image', $2, '   ')`,
        [author.id, `${author.id}/blank.jpg`],
      ),
    /posts_caption_not_blank/,
  );
});
