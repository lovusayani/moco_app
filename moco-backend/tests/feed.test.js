'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');

const { createApp } = require('../src/app');
const db = require('../src/config/db');
const redisConfig = require('../src/config/redis');
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

// --- likes, comments, shares, follow from the feed ---------------------------

async function followableAuthor() {
  const author = await createUser({ listener: true });
  // Eligible = approved KYC + the minimum photo count (photos are not under test).
  await query('UPDATE listener_profiles SET photo_count = 3 WHERE user_id = $1', [author.id]);
  return author;
}

const notificationsOf = async (userId, type) =>
  (await query('SELECT * FROM notifications WHERE user_id = $1 AND type = $2', [userId, type])).rows;

test('feed posts carry zeroed counters and follow state for a new viewer', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await followableAuthor();
  await createPost({ author });
  const feed = await call('GET', '/api/feed', { token: signToken(viewer) });
  const [post] = feed.body.posts;
  assert.equal(post.likeCount, 0);
  assert.equal(post.liked, false);
  assert.equal(post.commentCount, 0);
  assert.equal(post.shareCount, 0);
  assert.equal(post.author.canFollow, true);
  assert.equal(post.author.isFollowing, false);

  // Your own post is never followable.
  const own = await call('GET', '/api/feed', { token: signToken(author) });
  assert.equal(own.body.posts[0].author.canFollow, false);
});

test('follow from the feed uses the existing listener follow and shows in the feed', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await followableAuthor();
  await createPost({ author });
  const token = signToken(viewer);

  const followed = await call('PUT', `/api/listeners/${author.id}/follow`, { token });
  assert.equal(followed.status, 200);
  assert.equal(followed.body.followerCount, 1);
  let feed = await call('GET', '/api/feed', { token });
  assert.equal(feed.body.posts[0].author.isFollowing, true);

  // Re-follow and unfollow/follow churn notify the listener exactly once.
  await call('PUT', `/api/listeners/${author.id}/follow`, { token });
  await call('DELETE', `/api/listeners/${author.id}/follow`, { token });
  await call('PUT', `/api/listeners/${author.id}/follow`, { token });
  assert.equal((await notificationsOf(author.id, 'new_follower')).length, 1);

  const unfollowed = await call('DELETE', `/api/listeners/${author.id}/follow`, { token });
  assert.equal(unfollowed.body.followerCount, 0);
  feed = await call('GET', '/api/feed', { token });
  assert.equal(feed.body.posts[0].author.isFollowing, false);
});

test('like and unlike are idempotent, counted once, and persist', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();
  const author = await createUser();
  const post = await createPost({ author });

  const first = await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(a) });
  assert.equal(first.status, 200);
  assert.deepEqual([first.body.liked, first.body.likeCount], [true, 1]);
  const again = await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(a) });
  assert.deepEqual([again.body.liked, again.body.likeCount], [true, 1], 'a repeated like must not double-count');
  const other = await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(b) });
  assert.equal(other.body.likeCount, 2);

  // Survives a reload: the feed reports the persisted state per viewer.
  const feedA = await call('GET', '/api/feed', { token: signToken(a) });
  assert.deepEqual([feedA.body.posts[0].liked, feedA.body.posts[0].likeCount], [true, 2]);

  const unliked = await call('DELETE', `/api/feed/${post.id}/like`, { token: signToken(a) });
  assert.deepEqual([unliked.body.liked, unliked.body.likeCount], [false, 1]);
  const unlikedAgain = await call('DELETE', `/api/feed/${post.id}/like`, { token: signToken(a) });
  assert.equal(unlikedAgain.body.likeCount, 1);

  // One like notification per liker per post, even after unlike + like.
  await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(a) });
  assert.equal((await notificationsOf(author.id, 'post_like')).length, 2);
});

test('liking your own post does not notify you', async () => {
  await resetDb();
  const author = await createUser();
  const post = await createPost({ author });
  const liked = await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(author) });
  assert.equal(liked.body.likeCount, 1);
  assert.equal((await notificationsOf(author.id, 'post_like')).length, 0);
});

test('a blocked or removed post cannot be liked, commented on or shared', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();
  const removed = await createPost({ author, status: 'removed' });
  for (const [method, path, body] of [
    ['PUT', `/api/feed/${removed.id}/like`],
    ['POST', `/api/feed/${removed.id}/comments`, { body: 'hi' }],
    ['POST', `/api/feed/${removed.id}/share`, {}],
    ['GET', `/api/feed/${removed.id}`],
  ]) {
    const result = await call(method, path, { token: signToken(viewer), body });
    assert.equal(result.status, 404, `${method} ${path}`);
  }

  const post = await createPost({ author });
  await query('INSERT INTO blocks (blocker_id, blocked_id) VALUES ($1, $2)', [author.id, viewer.id]);
  const blocked = await call('PUT', `/api/feed/${post.id}/like`, { token: signToken(viewer) });
  assert.equal(blocked.status, 404);
});

test('comments: add, load newest first, count, and notify the author', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();
  const post = await createPost({ author });
  const token = signToken(viewer);

  const blank = await call('POST', `/api/feed/${post.id}/comments`, { token, body: { body: '   ' } });
  assert.equal(blank.status, 400);
  const tooLong = await call('POST', `/api/feed/${post.id}/comments`, { token, body: { body: 'x'.repeat(501) } });
  assert.equal(tooLong.status, 400);

  const one = await call('POST', `/api/feed/${post.id}/comments`, { token, body: { body: '  first  ' } });
  assert.equal(one.status, 201);
  assert.equal(one.body.comment.body, 'first');
  assert.equal(one.body.comment.isOwn, true);
  assert.equal(one.body.comment.canDelete, true);
  assert.equal(one.body.commentCount, 1);
  const two = await call('POST', `/api/feed/${post.id}/comments`, { token, body: { body: 'second' } });
  assert.equal(two.body.commentCount, 2);

  const list = await call('GET', `/api/feed/${post.id}/comments`, { token });
  assert.equal(list.status, 200);
  assert.deepEqual(list.body.comments.map((c) => c.body), ['second', 'first']);
  assert.equal(list.body.commentCount, 2);
  assert.equal(list.body.comments[0].author.id, viewer.id);

  const feed = await call('GET', '/api/feed', { token });
  assert.equal(feed.body.posts[0].commentCount, 2);

  // Two quick comments from one person: one notification (10-minute window).
  assert.equal((await notificationsOf(author.id, 'post_comment')).length, 1);
});

test('comments: the commenter or the post author may delete; nobody else', async () => {
  await resetDb();
  const commenter = await createUser();
  const author = await createUser();
  const stranger = await createUser();
  const post = await createPost({ author });
  const c1 = await call('POST', `/api/feed/${post.id}/comments`, { token: signToken(commenter), body: { body: 'a' } });
  const c2 = await call('POST', `/api/feed/${post.id}/comments`, { token: signToken(commenter), body: { body: 'b' } });

  const asAuthor = await call('GET', `/api/feed/${post.id}/comments`, { token: signToken(author) });
  assert.equal(asAuthor.body.comments[0].canDelete, true);
  const asStranger = await call('GET', `/api/feed/${post.id}/comments`, { token: signToken(stranger) });
  assert.equal(asStranger.body.comments[0].canDelete, false);

  const denied = await call('DELETE', `/api/feed/${post.id}/comments/${c1.body.comment.id}`, {
    token: signToken(stranger),
  });
  assert.equal(denied.status, 403);

  const own = await call('DELETE', `/api/feed/${post.id}/comments/${c1.body.comment.id}`, {
    token: signToken(commenter),
  });
  assert.deepEqual([own.status, own.body.commentCount], [200, 1]);
  const moderated = await call('DELETE', `/api/feed/${post.id}/comments/${c2.body.comment.id}`, {
    token: signToken(author),
  });
  assert.deepEqual([moderated.status, moderated.body.commentCount], [200, 0]);
});

test('share is counted only when recorded, once per user per post per hour', async () => {
  await resetDb();
  const a = await createUser();
  const b = await createUser();
  const author = await createUser();
  const post = await createPost({ author });

  // Loading the feed or the post is not a share.
  await call('GET', '/api/feed', { token: signToken(a) });
  await call('GET', `/api/feed/${post.id}`, { token: signToken(a) });
  assert.equal((await call('GET', '/api/feed', { token: signToken(a) })).body.posts[0].shareCount, 0);

  const first = await call('POST', `/api/feed/${post.id}/share`, { token: signToken(a), body: { method: 'copy' } });
  assert.deepEqual([first.status, first.body.shareCount, first.body.counted], [200, 1, true]);
  const repeat = await call('POST', `/api/feed/${post.id}/share`, { token: signToken(a), body: { method: 'native' } });
  assert.deepEqual([repeat.body.shareCount, repeat.body.counted], [1, false]);
  const other = await call('POST', `/api/feed/${post.id}/share`, { token: signToken(b), body: {} });
  assert.equal(other.body.shareCount, 2);

  const feed = await call('GET', '/api/feed', { token: signToken(b) });
  assert.equal(feed.body.posts[0].shareCount, 2);
  const shareNotes = await query("SELECT count(*)::int AS n FROM notifications WHERE type LIKE '%share%'");
  assert.equal(shareNotes.rows[0].n, 0, 'sharing never notifies');
});

test('a single post loads by id for a shared link', async () => {
  await resetDb();
  const viewer = await createUser();
  const author = await createUser();
  const post = await createPost({ author, caption: 'linked' });
  const one = await call('GET', `/api/feed/${post.id}`, { token: signToken(viewer) });
  assert.equal(one.status, 200);
  assert.equal(one.body.post.id, post.id);
  assert.equal(one.body.post.caption, 'linked');
  const missing = await call('GET', '/api/feed/999999', { token: signToken(viewer) });
  assert.equal(missing.status, 404);
});
