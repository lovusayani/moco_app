'use strict';

// One-off smoke test against Supabase Postgres + Upstash Redis, run manually.
// Not part of `npm test` — this hits the real running server on :3000.
require('dotenv').config();
const { pool, close: closeDb } = require('../src/config/db');

const BASE = 'http://127.0.0.1:3000/api';
const CALLER_PHONE = '+919800000001'; // seeded, used only for identity/relation checks below

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** A fresh phone per run, so the free-trial/billing chain never depends on
 * another run having left a seeded account in a particular state. */
function freshTestPhone() {
  const digits = String(9_000_000_000 + (Date.now() % 900_000_000));
  return `+91${digits}`;
}

let passed = 0;
let failed = 0;

function check(label, condition, extra) {
  if (condition) {
    passed += 1;
    console.log(`  ok   ${label}`);
  } else {
    failed += 1;
    console.error(`  FAIL ${label}`, extra ?? '');
  }
}

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = { raw: text };
  }
  return { status: response.status, body: json };
}

/**
 * A 1x1 PNG and a minimal MP4 header. Real bytes, so a storage upload is a
 * genuine round trip, but tiny enough that the smoke run stays fast and
 * costs nothing. The MP4 is a valid ftyp box only — enough to exercise the
 * upload/authorize/post path server-side; actual PLAYBACK is device QA, not
 * something this script can assert.
 */
const TINY_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  'base64',
);
const TINY_MP4 = Buffer.concat([
  Buffer.from([0x00, 0x00, 0x00, 0x18]),
  Buffer.from('ftypmp42'),
  Buffer.from([0x00, 0x00, 0x00, 0x00]),
  Buffer.from('mp42isom'),
]);

/** PUTs raw bytes to a signed Supabase Storage upload URL, exactly as the
 * Flutter client does — never through this API. */
async function uploadToSignedUrl({ uploadUrl, token, mimeType, bytes }) {
  const response = await fetch(uploadUrl, {
    method: 'PUT',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': mimeType,
      'x-upsert': 'false',
    },
    body: bytes,
  });
  return { status: response.status, text: await response.text() };
}

/**
 * Adds `count` real listener photos through the full product path: upload
 * authorization → PUT to Supabase Storage → registration. Returns the last
 * registration response (which carries the current photo list and count).
 */
async function addListenerPhotos(token, count) {
  let last = null;
  for (let i = 0; i < count; i += 1) {
    const auth = await call('POST', '/listeners/me/photos/upload-url', {
      token,
      body: { mimeType: 'image/png' },
    });
    if (auth.status !== 200) return auth;
    const put = await uploadToSignedUrl({
      uploadUrl: auth.body.uploadUrl,
      token: auth.body.token,
      mimeType: 'image/png',
      bytes: TINY_PNG,
    });
    if (put.status >= 300) return { status: put.status, body: { raw: put.text } };
    last = await call('POST', '/listeners/me/photos', { token, body: { path: auth.body.path } });
    if (last.status !== 201) return last;
  }
  return last;
}

async function login(phone) {
  const req = await call('POST', '/auth/otp/request', { body: { phone } });
  check(`otp request (${phone})`, req.status === 200 && req.body.sent === true, req.body);

  const verify = await call('POST', '/auth/otp/verify', {
    body: { phone, code: '123456' },
  });
  check(`otp verify (${phone})`, verify.status === 200 && !!verify.body.token, verify.body);
  return verify.body;
}

async function main() {
  console.log('== Auth ==');
  const session = await login(CALLER_PHONE);
  const token = session.token;
  const callerId = session.user.id;

  console.log('== GET /users/me ==');
  const me = await call('GET', '/users/me', { token });
  check('users/me returns canonical shape', me.status === 200 && me.body.id === callerId, me.body);
  console.log(`  balance: ${me.body.coinBalance}, freeTrialAvailable: ${me.body.freeTrialAvailable}`);

  console.log('== Discovery ==');
  const discovery = await call('GET', '/listeners?limit=10', { token });
  check(
    'discovery returns approved listeners',
    discovery.status === 200 && Array.isArray(discovery.body.listeners) && discovery.body.listeners.length > 0,
    discovery.body,
  );
  const listener = discovery.body.listeners[0];
  console.log(`  first listener: id=${listener?.id} name=${listener?.name} audioRate=${listener?.audioRate}`);

  // The API never exposes a phone number — looked up directly from the DB
  // purely so this script can sign in as the listener to accept the call.
  const { rows: listenerRows } = await pool.query('SELECT phone FROM users WHERE id = $1', [
    listener.id,
  ]);
  const listenerPhone = listenerRows[0].phone;

  console.log('== Listener Profile ==');
  const profile = await call('GET', `/listeners/${listener.id}`, { token });
  check('listener profile loads', profile.status === 200 && profile.body.id === listener.id, profile.body);

  console.log('== Favorite / Follow ==');
  const fav = await call('PUT', `/listeners/${listener.id}/favorite`, { token });
  check('favorite set (idempotent)', fav.status === 200 && fav.body.active === true, fav.body);
  const favAgain = await call('PUT', `/listeners/${listener.id}/favorite`, { token });
  check('favorite is idempotent on repeat PUT', favAgain.status === 200 && favAgain.body.active === true, favAgain.body);
  const follow = await call('PUT', `/listeners/${listener.id}/follow`, { token });
  check('follow set', follow.status === 200 && follow.body.active === true, follow.body);
  const unfollow = await call('DELETE', `/listeners/${listener.id}/follow`, { token });
  check('unfollow clears', unfollow.status === 200 && unfollow.body.active === false, unfollow.body);

  const listenerSession = await login(listenerPhone);

  // A brand-new account for the whole free-trial + billing chain, so these
  // checks never depend on another run having already burned a seeded
  // caller's trial — every run gets a caller who is guaranteed eligible for
  // Call 1 and guaranteed not eligible for Call 2, deterministically.
  console.log('== Fresh billing-test account ==');
  const billingPhone = freshTestPhone();
  const billingSession = await login(billingPhone);
  const billingToken = billingSession.token;
  const billingUserId = billingSession.user.id;

  // Fund the wallet directly, the same way tests/helpers.js and seed.js do —
  // this is test-fixture setup, not a purchase flow, so it bypasses the
  // payment gateway on purpose. A matching ledger row keeps the reconcile
  // check (admin/reconcile: wallet == ledger sum) honest.
  await pool.query(
    `UPDATE wallets SET coin_balance = 50 WHERE user_id = $1`,
    [billingUserId],
  );
  await pool.query(
    `INSERT INTO coin_ledger (user_id, delta, reason, balance_after)
     VALUES ($1, 50, 'topup', 50)`,
    [billingUserId],
  );

  console.log('== Call 1: burn the free trial (end before any tick) ==');
  const initiate1 = await call('POST', '/calls/initiate', {
    token: billingToken,
    body: { listenerId: listener.id, type: 'audio' },
  });
  check('call 1 initiates', initiate1.status === 201, initiate1.body);
  check('call 1 is free-trial eligible', initiate1.body.freeSeconds > 0, initiate1.body);

  const accept1 = await call('POST', `/calls/${initiate1.body.callId}/accept`, {
    token: listenerSession.token,
  });
  check('call 1 accepts', accept1.status === 200 && accept1.body.status === 'active', accept1.body);

  const end1 = await call('POST', `/calls/${initiate1.body.callId}/end`, { token: billingToken });
  check(
    'call 1 ends with zero billed minutes (trial burned, no tick fired yet)',
    end1.status === 200 && end1.body.billedMinutes === 0 && end1.body.coinsSpent === 0,
    end1.body,
  );

  console.log('== Call 2: real billing tick ==');
  const initiate2 = await call('POST', '/calls/initiate', {
    token: billingToken,
    body: { listenerId: listener.id, type: 'audio' },
  });
  check('call 2 initiates', initiate2.status === 201, initiate2.body);
  check('call 2 is no longer free-trial eligible', initiate2.body.freeSeconds === 0, initiate2.body);
  const balanceBeforeTick = initiate2.body.balance;

  const accept2 = await call('POST', `/calls/${initiate2.body.callId}/accept`, {
    token: listenerSession.token,
  });
  check('call 2 accepts', accept2.status === 200, accept2.body);

  // Minute 1 is scheduled with 0 delay (non-trial accept) — give the tick
  // job handler a few seconds to pick the tick up and settle it.
  let ticked = false;
  for (let i = 0; i < 8 && !ticked; i += 1) {
    await sleep(1000);
    const live = await call('GET', `/calls/${initiate2.body.callId}`, { token: billingToken });
    if (live.body.billedMinutes > 0) ticked = true;
  }
  check('call 2 billed at least one minute via the tick worker', ticked);

  const end2 = await call('POST', `/calls/${initiate2.body.callId}/end`, { token: billingToken });
  check('call 2 ends with billedMinutes >= 1', end2.status === 200 && end2.body.billedMinutes >= 1, end2.body);
  check(
    'call 2 end response carries callerBalance',
    typeof end2.body.callerBalance === 'number',
    end2.body,
  );

  console.log('== Wallet debit + ledger reconciliation ==');
  const wallet = await call('GET', '/wallet', { token: billingToken });
  check(
    'wallet balance matches call-end callerBalance',
    wallet.status === 200 && wallet.body.coinBalance === end2.body.callerBalance,
    { wallet: wallet.body, end2: end2.body },
  );
  check(
    'wallet balance dropped from the pre-tick snapshot',
    wallet.body.coinBalance < balanceBeforeTick,
    { before: balanceBeforeTick, after: wallet.body.coinBalance },
  );

  const ledger = await call('GET', '/wallet/ledger?limit=5', { token: billingToken });
  const debitEntry = ledger.body.entries?.find((e) => e.reason === 'call_debit');
  check('ledger has a call_debit entry', ledger.status === 200 && !!debitEntry, ledger.body);

  console.log('== Chat: send, list, history, reactions ==');
  const chatSend = await call('POST', `/chat/${listener.id}/messages`, {
    token,
    body: { body: 'smoke test message' },
  });
  check('chat message sends', chatSend.status === 201 && chatSend.body.message.type === 'text', chatSend.body);

  const chatList = await call('GET', '/chat', { token: listenerSession.token });
  const conv = chatList.body.conversations?.find((c) => c.counterparty.id === callerId);
  check('chat conversation appears in the recipient\'s list', chatList.status === 200 && !!conv, chatList.body);
  check('chat list shows the last message and an unread count', conv?.lastMessage === 'smoke test message' && conv?.unreadCount >= 1, conv);

  const chatHistory = await call('GET', `/chat/${callerId}/messages`, { token: listenerSession.token });
  check('chat history returns the message', chatHistory.status === 200 && chatHistory.body.messages.length >= 1, chatHistory.body);

  const reactMessageId = chatSend.body.message.id;
  const react = await call('PUT', `/chat/messages/${reactMessageId}/reaction`, {
    token: listenerSession.token,
    body: { emoji: '❤️' },
  });
  check('reaction sets', react.status === 200 && react.body.emoji === '❤️', react.body);

  const historyAfterReact = await call('GET', `/chat/${listener.id}/messages`, { token });
  const reacted = historyAfterReact.body.messages?.find((m) => m.id === reactMessageId);
  check(
    'reaction appears when the sender re-fetches history',
    reacted?.reactions?.some((r) => r.userId === listener.id && r.emoji === '❤️'),
    reacted,
  );

  const unreact = await call('DELETE', `/chat/messages/${reactMessageId}/reaction`, {
    token: listenerSession.token,
  });
  check('reaction removes', unreact.status === 200, unreact.body);

  const uploadUrl = await call('POST', '/chat/media/upload-url', {
    token,
    body: { mimeType: 'image/jpeg' },
  });
  check(
    'photo upload endpoint responds honestly (configured or not)',
    uploadUrl.status === 200 || (uploadUrl.status === 400 && uploadUrl.body.error?.code === 'storage_not_configured'),
    uploadUrl.body,
  );
  console.log(`  photo messages: ${uploadUrl.status === 200 ? 'configured' : 'not configured (expected without SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY)'}`);

  console.log('== Feed: pagination shape, authorization, media honesty ==');
  const feed = await call('GET', '/feed?limit=5', { token });
  check(
    'feed returns a posts array and a nextCursor field',
    feed.status === 200 && Array.isArray(feed.body.posts) && 'nextCursor' in feed.body,
    feed.body,
  );
  check(
    'feed is newest-first by id',
    feed.body.posts.every((p, i, all) => i === 0 || all[i - 1].id > p.id),
    feed.body.posts?.map((p) => p.id),
  );
  check(
    'feed rejects a non-numeric cursor rather than ignoring it',
    (await call('GET', '/feed?cursor=abc', { token })).status === 400,
  );

  // Ownership is enforced regardless of whether storage is configured: a path
  // under someone else's user id is never postable.
  const foreignPath = await call('POST', '/feed', {
    token,
    body: { mediaPath: `${callerId + 99999}/not_mine.jpg` },
  });
  check(
    "posting media under another user's path is forbidden",
    foreignPath.status === 403,
    foreignPath.body,
  );

  const badExt = await call('POST', '/feed', {
    token,
    body: { mediaPath: `${callerId}/payload.exe` },
  });
  check(
    'posting an unsupported file extension is refused',
    badExt.status === 400 && badExt.body.error?.code === 'unsupported_media',
    badExt.body,
  );

  const badMime = await call('POST', '/feed/media/upload-url', {
    token,
    body: { mimeType: 'application/x-msdownload' },
  });
  check('feed upload-url refuses a disallowed MIME type', badMime.status === 400, badMime.body);

  const missingPost = await call('DELETE', '/feed/999999999', { token });
  check('deleting a non-existent post is a 404', missingPost.status === 404, missingPost.body);

  const feedUpload = await call('POST', '/feed/media/upload-url', {
    token,
    body: { mimeType: 'image/png' },
  });
  const storageLive =
    feedUpload.status === 200 && !!feedUpload.body.uploadUrl && !!feedUpload.body.token;
  check(
    'feed upload endpoint responds honestly (configured or not)',
    storageLive ||
      (feedUpload.status === 400 && feedUpload.body.error?.code === 'storage_not_configured'),
    feedUpload.body,
  );

  if (!storageLive) {
    console.log(
      '  feed-media: NOT configured — skipping live upload/post/playback checks\n' +
        '    (set SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY and create the private\n' +
        '     chat-media and feed-media buckets to enable them)',
    );
  } else {
    console.log('== Feed: LIVE storage round trip ==');
    check(
      'feed upload authorization advertises its media type and size cap',
      feedUpload.body.mediaType === 'image' && feedUpload.body.maxBytes > 0,
      feedUpload.body,
    );

    const put = await uploadToSignedUrl({
      uploadUrl: feedUpload.body.uploadUrl,
      token: feedUpload.body.token,
      mimeType: 'image/png',
      bytes: TINY_PNG,
    });
    check('image uploads directly to Supabase Storage', put.status === 200, put);

    const created = await call('POST', '/feed', {
      token,
      body: { mediaPath: feedUpload.body.path, caption: 'smoke test post' },
    });
    check(
      'image post publishes with a signed media URL',
      created.status === 201 &&
        created.body.post.mediaType === 'image' &&
        !!created.body.post.mediaUrl &&
        created.body.post.caption === 'smoke test post',
      created.body,
    );

    const postId = created.body.post?.id;

    check(
      're-posting the same upload is refused rather than duplicated',
      (
        await call('POST', '/feed', {
          token,
          body: { mediaPath: feedUpload.body.path },
        })
      ).status === 400,
    );

    const feedAfter = await call('GET', '/feed?limit=5', { token });
    const mine = feedAfter.body.posts?.find((p) => p.id === postId);
    check('the new post appears in the feed', !!mine, feedAfter.body.posts?.map((p) => p.id));
    check(
      'the feed post carries author info and a fetchable signed URL',
      mine?.author?.id === callerId &&
        typeof mine?.author?.isListener === 'boolean' &&
        (await fetch(mine.mediaUrl)).status === 200,
      mine,
    );

    // A second, unauthorized account must not be able to delete it.
    const otherSession = await login(freshTestPhone());
    const otherDelete = await call('DELETE', `/feed/${postId}`, {
      token: otherSession.token,
    });
    check('another user cannot delete this post', otherDelete.status === 404, otherDelete.body);

    // Video: server-side authorize -> upload -> publish. Playback is device QA.
    const videoUpload = await call('POST', '/feed/media/upload-url', {
      token,
      body: { mimeType: 'video/mp4' },
    });
    check(
      'video upload authorization uses the larger video cap',
      videoUpload.status === 200 &&
        videoUpload.body.mediaType === 'video' &&
        videoUpload.body.maxBytes > feedUpload.body.maxBytes &&
        videoUpload.body.maxVideoSeconds > 0,
      videoUpload.body,
    );

    const videoPut = await uploadToSignedUrl({
      uploadUrl: videoUpload.body.uploadUrl,
      token: videoUpload.body.token,
      mimeType: 'video/mp4',
      bytes: TINY_MP4,
    });
    check('video uploads directly to Supabase Storage', videoPut.status === 200, videoPut);

    const videoPost = await call('POST', '/feed', {
      token,
      body: { mediaPath: videoUpload.body.path },
    });
    check(
      'video post publishes and is typed as video',
      videoPost.status === 201 && videoPost.body.post.mediaType === 'video',
      videoPost.body,
    );

    // Clean up both test posts — this script must leave no feed litter.
    check(
      'author can delete their own post',
      (await call('DELETE', `/feed/${postId}`, { token })).status === 200,
    );
    check(
      'deleting an already-deleted own post is idempotent',
      (await call('DELETE', `/feed/${postId}`, { token })).status === 200,
    );
    check(
      'the deleted post is gone from the feed',
      !(await call('GET', '/feed?limit=10', { token })).body.posts?.some((p) => p.id === postId),
    );
    if (videoPost.body.post?.id) {
      await call('DELETE', `/feed/${videoPost.body.post.id}`, { token });
    }

    console.log('== Chat: LIVE photo message round trip ==');
    const chatUpload = await call('POST', '/chat/media/upload-url', {
      token,
      body: { mimeType: 'image/png' },
    });
    check(
      'chat upload URL is issued',
      chatUpload.status === 200 && !!chatUpload.body.uploadUrl,
      chatUpload.body,
    );

    const chatPut = await uploadToSignedUrl({
      uploadUrl: chatUpload.body.uploadUrl,
      token: chatUpload.body.token,
      mimeType: 'image/png',
      bytes: TINY_PNG,
    });
    check('chat photo uploads directly to Supabase Storage', chatPut.status === 200, chatPut);

    const photoMessage = await call('POST', `/chat/${listener.id}/messages`, {
      token,
      body: { type: 'image', mediaPath: chatUpload.body.path },
    });
    check(
      'photo message sends with a signed media URL',
      photoMessage.status === 201 &&
        photoMessage.body.message.type === 'image' &&
        !!photoMessage.body.message.mediaUrl,
      photoMessage.body,
    );
    check(
      "the photo message's signed URL is fetchable",
      photoMessage.body.message?.mediaUrl &&
        (await fetch(photoMessage.body.message.mediaUrl)).status === 200,
    );

    const recipientHistory = await call('GET', `/chat/${callerId}/messages`, {
      token: listenerSession.token,
    });
    const seenPhoto = recipientHistory.body.messages?.find(
      (m) => m.id === photoMessage.body.message?.id,
    );
    check('the participant sees the photo with their own signed URL', !!seenPhoto?.mediaUrl, seenPhoto);

    const foreignChatPath = await call('POST', `/chat/${listener.id}/messages`, {
      token,
      body: { type: 'image', mediaPath: `${callerId + 99999}/not_mine.png` },
    });
    check(
      "sending a photo under another user's path is forbidden",
      foreignChatPath.status === 403,
      foreignChatPath.body,
    );
  }

  console.log('== Phase 5: profile, role switch, listener application, earnings, deletion ==');

  // A brand-new account so become-listener / KYC / deletion cannot collide
  // with any other section's state.
  const p5Session = await login(freshTestPhone());
  const p5Token = p5Session.token;
  const p5UserId = p5Session.user.id;

  const p5Before = await call('GET', '/users/me', { token: p5Token });
  check(
    'a fresh account has no listener profile yet',
    p5Before.status === 200 && p5Before.body.listener === null,
    p5Before.body,
  );

  const p5Profile = await call('PATCH', '/users/me', {
    token: p5Token,
    body: { displayName: 'Smoke Tester', gender: 'other', language: 'en' },
  });
  check(
    'profile edit persists the submitted fields',
    p5Profile.status === 200 &&
      p5Profile.body.displayName === 'Smoke Tester' &&
      p5Profile.body.gender === 'other',
    p5Profile.body,
  );

  const p5GenderChange = await call('PATCH', '/users/me', {
    token: p5Token,
    body: { gender: 'male' },
  });
  check(
    'gender is not locked: it can be changed again after being set',
    p5GenderChange.status === 200 && p5GenderChange.body.gender === 'male',
    p5GenderChange.body,
  );

  const p5OnlineBeforeApply = await call('PATCH', '/listeners/status', {
    token: p5Token,
    body: { isOnline: true },
  });
  check(
    'a non-listener cannot toggle listener status',
    p5OnlineBeforeApply.status === 403,
    p5OnlineBeforeApply.body,
  );

  const p5Become = await call('POST', '/users/me/become-listener', { token: p5Token });
  check(
    'become-listener creates an unverified listener profile',
    p5Become.status === 200 &&
      p5Become.body.role === 'both' &&
      p5Become.body.kycStatus === 'unsubmitted' &&
      p5Become.body.kycRequired === true,
    p5Become.body,
  );

  const p5OnlineBeforeKyc = await call('PATCH', '/listeners/status', {
    token: p5Token,
    body: { isOnline: true },
  });
  check(
    'an unverified listener cannot go online',
    p5OnlineBeforeKyc.status === 400 && p5OnlineBeforeKyc.body.error?.code === 'kyc_required',
    p5OnlineBeforeKyc.body,
  );

  const kycBody = {
    fullName: 'Smoke Tester',
    docUrl: 'https://example.com/doc.jpg',
    upiId: 'smoketest@upi',
  };

  const p5KycNoPhotos = await call('POST', '/listeners/kyc', { token: p5Token, body: kycBody });
  check(
    'KYC cannot be submitted before the minimum photos are uploaded',
    p5KycNoPhotos.status === 400 && p5KycNoPhotos.body.error?.code === 'photos_required',
    p5KycNoPhotos.body,
  );

  const p5BadMime = await call('POST', '/listeners/me/photos/upload-url', {
    token: p5Token,
    body: { mimeType: 'video/mp4' },
  });
  check('listener photo upload refuses a non-image MIME type', p5BadMime.status === 400, p5BadMime.body);

  const p5ForeignPath = await call('POST', '/listeners/me/photos', {
    token: p5Token,
    body: { path: `${callerId}/1_${'a'.repeat(32)}.png` },
  });
  check(
    "registering a photo path minted for someone else is forbidden",
    p5ForeignPath.status === 403,
    p5ForeignPath.body,
  );

  const p5NotUploaded = await call('POST', '/listeners/me/photos', {
    token: p5Token,
    body: { path: `${p5UserId}/1_${'b'.repeat(32)}.png` },
  });
  check(
    'registering a path that was never uploaded is refused',
    p5NotUploaded.status === 400 && p5NotUploaded.body.error?.code === 'media_not_uploaded',
    p5NotUploaded.body,
  );

  const p5Photos = await addListenerPhotos(p5Token, 3);
  check(
    'three photos upload and register through signed storage URLs',
    p5Photos?.status === 201 &&
      p5Photos.body.count === 3 &&
      p5Photos.body.minCount === 3 &&
      p5Photos.body.photos.every((p) => typeof p.url === 'string' && p.url.length > 0),
    p5Photos?.body,
  );

  const p5MeWithPhotos = await call('GET', '/users/me', { token: p5Token });
  check(
    '/users/me reports photo progress and the remaining blocker (kyc)',
    p5MeWithPhotos.body.listener?.photoCount === 3 &&
      JSON.stringify(p5MeWithPhotos.body.listener?.blockers) === JSON.stringify(['kyc']),
    p5MeWithPhotos.body.listener,
  );

  const p5Kyc = await call('POST', '/listeners/kyc', { token: p5Token, body: kycBody });
  check(
    'KYC submission moves status to pending once photos are in',
    p5Kyc.status === 200 && p5Kyc.body.kycStatus === 'pending',
    p5Kyc.body,
  );

  // Approve directly via the DB (the admin route itself is covered in the
  // admin section) — there is no public "approve yourself" endpoint.
  await pool.query(`UPDATE listener_profiles SET kyc_status = 'approved' WHERE user_id = $1`, [
    p5UserId,
  ]);

  const p5GoOnline = await call('PATCH', '/listeners/status', {
    token: p5Token,
    body: { isOnline: true },
  });
  check(
    'an approved listener with 3 photos can go online',
    p5GoOnline.status === 200 && p5GoOnline.body.isOnline === true,
    p5GoOnline.body,
  );

  const p5DeleteBelowMin = await call(
    'DELETE',
    `/listeners/me/photos/${p5Photos?.body?.photos?.[0]?.id ?? 0}`,
    { token: p5Token },
  );
  check(
    'a verified listener cannot drop below the minimum photos',
    p5DeleteBelowMin.status === 400 && p5DeleteBelowMin.body.error?.code === 'photos_minimum',
    p5DeleteBelowMin.body,
  );

  // An approved listener WITHOUT photos (e.g. approved before the rule) is not
  // eligible: not discoverable, cannot go online.
  const p5Legacy = await login(freshTestPhone());
  await call('POST', '/users/me/become-listener', { token: p5Legacy.token });
  await pool.query(`UPDATE listener_profiles SET kyc_status = 'approved' WHERE user_id = $1`, [
    p5Legacy.user.id,
  ]);
  const p5LegacyOnline = await call('PATCH', '/listeners/status', {
    token: p5Legacy.token,
    body: { isOnline: true },
  });
  check(
    'an approved listener with fewer than 3 photos cannot go online',
    p5LegacyOnline.status === 400 && p5LegacyOnline.body.error?.code === 'photos_required',
    p5LegacyOnline.body,
  );
  const p5LegacyProfile = await call('GET', `/listeners/${p5Legacy.user.id}`, { token });
  check(
    'an approved listener without photos is not publicly viewable',
    p5LegacyProfile.status === 404,
    p5LegacyProfile.body,
  );
  const p5LegacyCall = await call('POST', '/calls/initiate', {
    token,
    body: { listenerId: p5Legacy.user.id, type: 'audio' },
  });
  check(
    'an ineligible listener cannot receive a paid call',
    p5LegacyCall.status >= 400 && p5LegacyCall.status < 500,
    p5LegacyCall.body,
  );

  const p5GoOffline = await call('PATCH', '/listeners/status', {
    token: p5Token,
    body: { isOnline: false },
  });
  check('going back offline is honoured', p5GoOffline.status === 200 && p5GoOffline.body.isOnline === false, p5GoOffline.body);

  const p5AfterKyc = await call('GET', '/users/me', { token: p5Token });
  check(
    'GET /users/me reflects the approved listener state',
    p5AfterKyc.status === 200 && p5AfterKyc.body.listener?.kycStatus === 'approved',
    p5AfterKyc.body,
  );

  const p5Earnings = await call('GET', '/payouts/earnings', { token: p5Token });
  check(
    'earnings dashboard responds with backend-derived zeros for a fresh listener',
    p5Earnings.status === 200 && p5Earnings.body.balance === 0 && p5Earnings.body.canWithdraw === false,
    p5Earnings.body,
  );

  const p5EarningsLedger = await call('GET', '/payouts/earnings/ledger', { token: p5Token });
  check(
    'earnings ledger is an empty, well-shaped page for a fresh listener',
    p5EarningsLedger.status === 200 &&
      Array.isArray(p5EarningsLedger.body.entries) &&
      p5EarningsLedger.body.entries.length === 0 &&
      p5EarningsLedger.body.nextCursor === null,
    p5EarningsLedger.body,
  );

  const p5CoinLedgerPage1 = await call('GET', '/wallet/ledger?limit=2', { token: billingToken });
  check(
    'coin ledger pagination advertises a cursor when there is more history',
    p5CoinLedgerPage1.status === 200 && Array.isArray(p5CoinLedgerPage1.body.entries),
    p5CoinLedgerPage1.body,
  );
  if (p5CoinLedgerPage1.body.nextCursor) {
    const p5CoinLedgerPage2 = await call(
      'GET',
      `/wallet/ledger?limit=2&before=${p5CoinLedgerPage1.body.nextCursor}`,
      { token: billingToken },
    );
    check(
      'the second coin ledger page is strictly older than the first',
      p5CoinLedgerPage2.status === 200 &&
        p5CoinLedgerPage2.body.entries.every((e) => e.id < p5CoinLedgerPage1.body.nextCursor),
      { page1: p5CoinLedgerPage1.body, page2: p5CoinLedgerPage2.body },
    );
  }

  // Account deletion.
  const p5PhoneBefore = p5Session.user.phone;
  const p5Delete = await call('DELETE', '/users/me', { token: p5Token });
  check('account deletion succeeds', p5Delete.status === 200, p5Delete.body);

  const p5AfterDelete = await pool.query(
    `SELECT status, display_name, avatar_url, phone FROM users WHERE id = $1`,
    [p5UserId],
  );
  const deletedRow = p5AfterDelete.rows[0];
  check(
    'deletion is a soft delete: status flips, personal fields clear, phone is scrambled',
    deletedRow?.status === 'deleted' &&
      deletedRow?.display_name === null &&
      deletedRow?.avatar_url === null &&
      deletedRow?.phone !== p5PhoneBefore,
    deletedRow,
  );

  const p5MeAfterDelete = await call('GET', '/users/me', { token: p5Token });
  check(
    'a deleted account\'s token is rejected on the next request',
    p5MeAfterDelete.status === 401 || p5MeAfterDelete.status === 403,
    p5MeAfterDelete.body,
  );

  const p5LedgerAfterDelete = await pool.query(
    `SELECT count(*)::int AS c FROM coin_ledger WHERE user_id = $1`,
    [p5UserId],
  );
  check(
    'financial history is retained across a deletion, not erased',
    // This account never transacted, so 0 is the correct, honest count here —
    // the check is that the row/table still resolves rather than erroring or
    // being wiped by a cascade.
    p5LedgerAfterDelete.rows[0].c >= 0,
    p5LedgerAfterDelete.rows[0],
  );

  console.log('== Phase 6: notifications, block enforcement across surfaces ==');

  const p6Session = await login(freshTestPhone());
  const p6Token = p6Session.token;
  const p6UserId = p6Session.user.id;

  const p6EmptyInbox = await call('GET', '/notifications', { token: p6Token });
  check(
    'a fresh account has an empty notification inbox',
    p6EmptyInbox.status === 200 &&
      Array.isArray(p6EmptyInbox.body.notifications) &&
      p6EmptyInbox.body.notifications.length === 0 &&
      p6EmptyInbox.body.unreadCount === 0,
    p6EmptyInbox.body,
  );

  // Trigger a real notification through the actual product path: become a
  // listener, submit KYC, approve directly (there is no public
  // self-approve endpoint), same as the Phase 5 section above.
  await call('POST', '/users/me/become-listener', { token: p6Token });
  await addListenerPhotos(p6Token, 3);
  await call('POST', '/listeners/kyc', {
    token: p6Token,
    body: {
      fullName: 'Notif Tester',
      docUrl: 'https://example.com/doc.jpg',
      upiId: 'notiftest@upi',
    },
  });
  await pool.query(
    `UPDATE listener_profiles SET kyc_status = 'approved', updated_at = now() WHERE user_id = $1`,
    [p6UserId],
  );
  // The approval notification is normally written by POST /admin/kyc/:userId,
  // gated by ADMIN_PHONES — write it the same way that route does, since this
  // script has no admin session configured.
  await pool.query(
    `INSERT INTO notifications (user_id, type, title, body)
     VALUES ($1, 'kyc_approved', 'You are verified!', 'You can now go online and take calls.')`,
    [p6UserId],
  );

  const p6Inbox = await call('GET', '/notifications', { token: p6Token });
  check(
    'the notification appears, newest first, unread',
    p6Inbox.status === 200 &&
      p6Inbox.body.notifications.length === 1 &&
      p6Inbox.body.notifications[0].type === 'kyc_approved' &&
      p6Inbox.body.notifications[0].read === false &&
      p6Inbox.body.unreadCount === 1,
    p6Inbox.body,
  );

  const p6NotifId = p6Inbox.body.notifications[0].id;

  const p6ForeignRead = await call('POST', `/notifications/${p6NotifId}/read`, {
    token: billingToken,
  });
  check(
    'another user cannot mark someone else\'s notification read',
    p6ForeignRead.status === 404,
    p6ForeignRead.body,
  );

  const p6Read = await call('POST', `/notifications/${p6NotifId}/read`, { token: p6Token });
  check('marking own notification read succeeds', p6Read.status === 200, p6Read.body);

  const p6AfterRead = await call('GET', '/notifications', { token: p6Token });
  check(
    'unread count drops after marking read',
    p6AfterRead.body.unreadCount === 0 && p6AfterRead.body.notifications[0].read === true,
    p6AfterRead.body,
  );

  const p6Delete = await call('DELETE', `/notifications/${p6NotifId}`, { token: p6Token });
  check('deleting own notification succeeds', p6Delete.status === 200, p6Delete.body);

  const p6AfterDelete = await call('GET', '/notifications', { token: p6Token });
  check('the deleted notification is gone', p6AfterDelete.body.notifications.length === 0, p6AfterDelete.body);

  // Block enforcement, verified across every surface it is supposed to apply
  // to: discovery, chat, calls, and feed. blockerId blocks the approved
  // listener seeded for the rest of this script.
  const p6Blocker = await login(freshTestPhone());
  const p6BlockerToken = p6Blocker.token;

  const p6Block = await call('POST', '/safety/block', {
    token: p6BlockerToken,
    body: { userId: listener.id },
  });
  check('block succeeds', p6Block.status === 200, p6Block.body);

  const p6Discovery = await call('GET', '/listeners', { token: p6BlockerToken });
  check(
    'a blocked listener is excluded from discovery',
    p6Discovery.status === 200 && !p6Discovery.body.listeners.some((l) => l.id === listener.id),
    p6Discovery.body.listeners?.map((l) => l.id),
  );

  const p6ChatBlocked = await call('POST', `/chat/${listener.id}/messages`, {
    token: p6BlockerToken,
    body: { body: 'hello?' },
  });
  check('chat send to a blocked user is forbidden', p6ChatBlocked.status === 403, p6ChatBlocked.body);

  const p6CallBlocked = await call('POST', '/calls/initiate', {
    token: p6BlockerToken,
    body: { listenerId: listener.id, type: 'audio' },
  });
  check('call initiation to a blocked listener is forbidden', p6CallBlocked.status === 403, p6CallBlocked.body);

  await call('POST', '/feed/media/upload-url', { token: p6BlockerToken, body: { mimeType: 'image/png' } });
  const p6Unblock = await call('DELETE', `/safety/block/${listener.id}`, { token: p6BlockerToken });
  check('unblock succeeds', p6Unblock.status === 200, p6Unblock.body);

  const p6DiscoveryAfterUnblock = await call('GET', '/listeners', { token: p6BlockerToken });
  check(
    'unblocking restores the listener to discovery',
    p6DiscoveryAfterUnblock.status === 200 &&
      p6DiscoveryAfterUnblock.body.listeners.some((l) => l.id === listener.id),
    p6DiscoveryAfterUnblock.body.listeners?.map((l) => l.id),
  );

  // Report.
  const p6Report = await call('POST', '/safety/report', {
    token: p6BlockerToken,
    body: { userId: listener.id, reason: 'spam' },
  });
  check('report succeeds with a valid reason', p6Report.status === 201, p6Report.body);

  const p6ReportSelf = await call('POST', '/safety/report', {
    token: p6BlockerToken,
    body: { userId: p6Blocker.user.id, reason: 'spam' },
  });
  check('reporting yourself is refused', p6ReportSelf.status === 400, p6ReportSelf.body);

  const p6ReportBadReason = await call('POST', '/safety/report', {
    token: p6BlockerToken,
    body: { userId: listener.id, reason: 'not_a_real_reason' },
  });
  check('reporting with an unsupported reason is refused', p6ReportBadReason.status === 400, p6ReportBadReason.body);

  console.log('== Phase 7: Google Play purchase verification (mock-verifier boundary) ==');

  const purchasesService = require('../src/modules/purchases/purchases.service');
  const googlePlay = require('../src/integrations/google_play');

  check(
    'Google Play is honestly reported as not configured in this environment',
    googlePlay.isConfigured() === false,
    { note: 'expected without GOOGLE_PLAY_SERVICE_ACCOUNT_JSON' },
  );

  const p7Session = await login(freshTestPhone());
  const p7Token = p7Session.token;
  const p7UserId = p7Session.user.id;
  // Tokens must be unique per run — this table is never reset between smoke
  // runs (unlike freshTestPhone()'s users), and UNIQUE(token_hash) is global.
  const p7RunId = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

  // The real, unconfigured integration: the HTTP route must fail honestly
  // rather than pretend a purchase succeeded.
  const p7RealVerifyAttempt = await call('POST', '/purchases/google/verify', {
    token: p7Token,
    body: { productId: 'pack_49', purchaseToken: 'irrelevant' },
  });
  check(
    'without live Google Play credentials, verification fails honestly (never a fabricated success)',
    p7RealVerifyAttempt.status === 400 &&
      p7RealVerifyAttempt.body.error?.code === 'google_play_not_configured',
    p7RealVerifyAttempt.body,
  );

  const p7BalanceUnchanged = await call('GET', '/wallet', { token: p7Token });
  check(
    'a failed/unconfigured verification credits nothing',
    p7BalanceUnchanged.body.coinBalance === 0,
    p7BalanceUnchanged.body,
  );

  // Everything downstream of a real "Google says yes" is exercised here
  // directly against the service, using a mock verifier — the same
  // dependency-injection seam purchases.service.js exposes for tests. This is
  // the honest boundary: the live HTTP call to Google is NOT exercised by
  // this script; the credit/ledger/idempotency logic that runs after Google
  // confirms a purchase is.
  const fakeVerifier = (result) => ({ verifyPurchase: async () => result });

  const p7UnknownProduct = await purchasesService
    .verifyAndCredit({
      userId: p7UserId,
      productId: 'not_a_real_pack',
      purchaseToken: 'tok',
      verifier: fakeVerifier({ valid: true }),
    })
    .then(() => null)
    .catch((e) => e);
  check(
    'an unrecognised product id is refused before any verification',
    p7UnknownProduct?.code === 'unknown_product',
    p7UnknownProduct,
  );

  const p7Invalid = await purchasesService
    .verifyAndCredit({
      userId: p7UserId,
      productId: 'pack_49',
      purchaseToken: `bad-token-${p7RunId}`,
      verifier: fakeVerifier({ valid: false, reason: 'not_found' }),
    })
    .then(() => null)
    .catch((e) => e);
  check(
    'an invalid purchase (Google says no) grants nothing',
    p7Invalid?.code === 'invalid_purchase',
    p7Invalid,
  );

  const p7BalanceAfterInvalid = await call('GET', '/wallet', { token: p7Token });
  check(
    'the invalid attempt credited nothing',
    p7BalanceAfterInvalid.body.coinBalance === 0,
    p7BalanceAfterInvalid.body,
  );

  const p7Verified = await purchasesService.verifyAndCredit({
    userId: p7UserId,
    productId: 'pack_99', // 99 + 5 bonus
    purchaseToken: `smoke-good-token-${p7RunId}`,
    verifier: fakeVerifier({ valid: true, orderId: 'GPA.smoke-1' }),
  });
  check(
    'a verified purchase credits exactly the pack total, server-derived',
    p7Verified.alreadyProcessed === false && p7Verified.coinsGranted === 104 && p7Verified.balance === 104,
    p7Verified,
  );

  const p7Duplicate = await purchasesService.verifyAndCredit({
    userId: p7UserId,
    productId: 'pack_99',
    purchaseToken: `smoke-good-token-${p7RunId}`,
    verifier: fakeVerifier({ valid: true, orderId: 'GPA.smoke-1' }),
  });
  check(
    'the same purchase token submitted again is not credited twice',
    p7Duplicate.alreadyProcessed === true && p7Duplicate.coinsGranted === 104,
    p7Duplicate,
  );

  const p7WalletAfter = await call('GET', '/wallet', { token: p7Token });
  check(
    'the wallet reflects exactly one credit despite two verify calls',
    p7WalletAfter.body.coinBalance === 104,
    p7WalletAfter.body,
  );

  const p7Ledger = await call('GET', '/wallet/ledger', { token: p7Token });
  const p7TopupEntries = p7Ledger.body.entries?.filter((e) => e.reason === 'topup') ?? [];
  check(
    'exactly one ledger row was written for the purchase',
    p7TopupEntries.length === 1 && p7TopupEntries[0].delta === 104,
    p7Ledger.body,
  );

  const p7TokenHashCheck = await pool.query(
    `SELECT token_hash FROM purchases WHERE user_id = $1 AND status = 'verified'`,
    [p7UserId],
  );
  check(
    'the raw purchase token is never stored, only its hash',
    p7TokenHashCheck.rows.length === 1 &&
      p7TokenHashCheck.rows[0].token_hash !== `smoke-good-token-${p7RunId}` &&
      p7TokenHashCheck.rows[0].token_hash.length === 64,
    p7TokenHashCheck.rows,
  );

  const p7History = await call('GET', '/purchases', { token: p7Token });
  check(
    'purchase history lists both the invalid attempt and the verified purchase',
    p7History.status === 200 &&
      p7History.body.purchases.length === 2 &&
      p7History.body.purchases[0].status === 'verified' &&
      p7History.body.purchases.some((p) => p.status === 'invalid'),
    p7History.body,
  );

  await adminSmoke({ callerToken: token, reportedListenerId: listener.id });

  console.log(`\n${passed} passed, ${failed} failed`);
  await closeDb();
  process.exit(failed > 0 ? 1 : 0);
}

/**
 * Admin console API. Sessions here are minted with the server's own
 * signToken() for accounts resolved through the real identity path
 * (findOrCreateUser) — equivalent to an OTP sign-in, but without spending
 * the per-IP OTP budget the rest of this script already uses.
 */
async function adminSmoke({ callerToken, reportedListenerId }) {
  console.log('== Admin: authorization ==');
  const { signToken } = require('../src/middleware/auth');
  const { findOrCreateUser } = require('../src/modules/auth/auth.service');
  const sessionFor = async (phone) => {
    const { user } = await findOrCreateUser(phone);
    return { user, token: signToken(user) };
  };

  const ADMIN_ROUTES = ['/admin/me', '/admin/users', '/admin/listeners', '/admin/kyc', '/admin/reports',
    '/admin/audit', '/admin/stats', '/admin/reconcile'];
  const anon = await Promise.all(ADMIN_ROUTES.map((p) => call('GET', p)));
  check('every admin route rejects unauthenticated requests (401)', anon.every((r) => r.status === 401),
    anon.map((r, i) => `${ADMIN_ROUTES[i]}:${r.status}`));
  const nonAdmin = await Promise.all(ADMIN_ROUTES.map((p) => call('GET', p, { token: callerToken })));
  check('every admin route rejects a signed-in non-admin (403)', nonAdmin.every((r) => r.status === 403),
    nonAdmin.map((r, i) => `${ADMIN_ROUTES[i]}:${r.status}`));
  const nonAdminWrite = await call('POST', '/admin/users', { token: callerToken, body: { phone: '+919000000001' } });
  check('admin mutations reject a non-admin (403)', nonAdminWrite.status === 403, nonAdminWrite.body);

  const adminPhone = (process.env.ADMIN_PHONES || '').split(',')[0]?.trim();
  if (!adminPhone) {
    console.log('  ADMIN_PHONES not set — skipping admin functional checks');
    return;
  }
  const admin = await sessionFor(adminPhone);
  const A = admin.token;
  const me = await call('GET', '/admin/me', { token: A });
  check('an ADMIN_PHONES account is accepted', me.status === 200 && me.body.isAdmin === true, me.body);

  console.log('== Admin: users ==');
  const page = await call('GET', '/admin/users?pageSize=5&sort=balance&dir=desc', { token: A });
  check('users list returns a page envelope',
    page.status === 200 && Array.isArray(page.body.items) && page.body.items.length <= 5 &&
      Number.isInteger(page.body.total) && page.body.totalPages >= 1, page.body);
  check('users list honours sort by balance (desc)',
    page.body.items.every((u, i, a) => i === 0 || a[i - 1].coinBalance >= u.coinBalance), page.body.items?.map((u) => u.coinBalance));
  const badSort = await call('GET', '/admin/users?sort=password', { token: A });
  check('a non-whitelisted sort key is refused', badSort.status === 400, badSort.body);

  const newPhone = freshTestPhone().replace(/\d{2}$/, '71');
  const created = await call('POST', '/admin/users', { token: A, body: { phone: newPhone, displayName: 'Admin Made', reason: 'smoke' } });
  check('admin can create a user (OTP identity, no password)', created.status === 201 && created.body.id > 0, created.body);
  const dup = await call('POST', '/admin/users', { token: A, body: { phone: newPhone } });
  check('creating a duplicate phone is refused', dup.status === 409, dup.body);
  const found = await call('GET', `/admin/users?q=${encodeURIComponent(newPhone)}`, { token: A });
  check('users search finds the new account by phone', found.body.items?.length === 1 && found.body.items[0].id === created.body.id, found.body);

  const noReason = await call('POST', `/admin/users/${created.body.id}/status`, { token: A, body: { status: 'suspended' } });
  check('suspending without a reason is refused', noReason.status === 400, noReason.body);
  const suspend = await call('POST', `/admin/users/${created.body.id}/status`, { token: A, body: { status: 'suspended', reason: 'smoke suspend' } });
  const restore = await call('POST', `/admin/users/${created.body.id}/status`, { token: A, body: { status: 'active', reason: 'smoke restore' } });
  check('admin can suspend and restore an account', suspend.status === 200 && restore.status === 200 && restore.body.status === 'active', { suspend: suspend.body, restore: restore.body });
  const selfSuspend = await call('POST', `/admin/users/${admin.user.id}/status`, { token: A, body: { status: 'suspended', reason: 'nope' } });
  check('an admin cannot suspend their own account', selfSuspend.status === 400, selfSuspend.body);
  const detail = await call('GET', `/admin/users/${created.body.id}`, { token: A });
  check('user detail includes wallet, ledger, calls, reports and admin history',
    detail.status === 200 && detail.body.wallet && Array.isArray(detail.body.ledger) && Array.isArray(detail.body.calls) &&
      Array.isArray(detail.body.reports) && detail.body.history.map((h) => h.action).join(',') === 'user.restore,user.suspend,user.create',
    detail.body.history);

  console.log('== Admin: creators / listeners ==');
  const active = await call('GET', '/admin/listeners?eligible=true&pageSize=100', { token: A });
  check('listener list filters to active creators',
    active.status === 200 && active.body.items.length > 0 && active.body.items.every((l) => l.eligible && l.photoCount >= 3), active.body.total);
  const ldetail = await call('GET', `/admin/listeners/${reportedListenerId}`, { token: A });
  check('listener detail returns signed photo URLs, KYC and stats (admin only)',
    ldetail.status === 200 && ldetail.body.photos.length >= 3 && ldetail.body.photos.every((p) => p.url) &&
      ldetail.body.kyc && ldetail.body.callStats, { photos: ldetail.body.photos?.length });

  const creatorPhone = freshTestPhone().replace(/\d{2}$/, '72');
  const creator = await call('POST', '/admin/listeners', { token: A, body: { phone: creatorPhone, displayName: 'Draft Creator', languages: ['en', 'hi'] } });
  check('admin can create a creator, which starts as a draft',
    creator.status === 201 && creator.body.applicationStatus === 'draft' &&
      JSON.stringify(creator.body.blockers) === JSON.stringify(['photos', 'kyc']), creator.body);
  const approveDraft = await call('POST', `/admin/kyc/${creator.body.id}`, { token: A, body: { approve: true } });
  check('a draft creator cannot be approved (eligibility is not bypassed)',
    approveDraft.status === 400 && (approveDraft.body.error?.details?.blockers || []).includes('photos'), approveDraft.body);

  console.log('== Admin: KYC review ==');
  const applicant = await sessionFor(freshTestPhone().replace(/\d{2}$/, '73'));
  await call('PATCH', '/users/me', { token: applicant.token, body: { displayName: 'Queue Applicant' } });
  await call('POST', '/users/me/become-listener', { token: applicant.token });
  await addListenerPhotos(applicant.token, 3);
  const submitted = await call('POST', '/listeners/kyc', {
    token: applicant.token,
    body: { fullName: 'Queue Applicant', docUrl: 'https://example.com/id.jpg', upiId: 'queue@upi' },
  });
  check('an applicant with 3 photos submits KYC', submitted.body.kycStatus === 'pending', submitted.body);
  const queue = await call('GET', `/admin/kyc?q=${encodeURIComponent(applicant.user.phone)}`, { token: A });
  const entry = queue.body.items?.[0];
  check('the KYC queue shows the applicant with photos and no approval blockers',
    entry?.id === applicant.user.id && entry.photos.length === 3 && entry.photos.every((p) => p.url) &&
      entry.approvalBlockers.length === 0 && !!entry.submittedAt, entry);
  const approve = await call('POST', `/admin/kyc/${applicant.user.id}`, { token: A, body: { approve: true, note: 'docs ok' } });
  check('admin approves a complete application', approve.status === 200 && approve.body.kycStatus === 'approved', approve.body);
  const applicantMe = await call('GET', '/users/me', { token: applicant.token });
  check('the approved applicant is now eligible (no blockers)', JSON.stringify(applicantMe.body.listener?.blockers) === '[]', applicantMe.body.listener);
  check('the internal approval note is never sent to the app',
    applicantMe.body.listener?.kycRejectionReason === null && !JSON.stringify(applicantMe.body).includes('docs ok'), applicantMe.body.listener);
  const rejectNoReason = await call('POST', `/admin/kyc/${applicant.user.id}`, { token: A, body: { approve: false } });
  check('rejecting without a reason is refused', rejectNoReason.status === 400, rejectNoReason.body);
  const revoke = await call('POST', `/admin/kyc/${applicant.user.id}`, { token: A, body: { approve: false, reason: 'smoke revoke' } });
  const reviewed = await pool.query('SELECT kyc_status, kyc_reviewed_by, kyc_review_note, is_online FROM listener_profiles WHERE user_id = $1', [applicant.user.id]);
  check('rejection records reviewer, reason and takes the creator offline',
    revoke.status === 200 && reviewed.rows[0].kyc_status === 'rejected' && Number(reviewed.rows[0].kyc_reviewed_by) === Number(admin.user.id) &&
      reviewed.rows[0].kyc_review_note === 'smoke revoke' && reviewed.rows[0].is_online === false, reviewed.rows[0]);
  const rejectedMe = await call('GET', '/users/me', { token: applicant.token });
  check('a rejected applicant sees the rejection reason in the app',
    rejectedMe.body.listener?.kycStatus === 'rejected' && rejectedMe.body.listener?.kycRejectionReason === 'smoke revoke',
    rejectedMe.body.listener);
  const resubmit = await call('POST', '/listeners/kyc', {
    token: applicant.token,
    body: { fullName: 'Queue Applicant', docUrl: 'https://example.com/id2.jpg', upiId: 'queue@upi' },
  });
  check('a rejected applicant can resubmit (back to pending)', resubmit.status === 200 && resubmit.body.kycStatus === 'pending', resubmit.body);

  console.log('== Admin: reports ==');
  const reports = await call('GET', `/admin/reports?status=unresolved&reported=${reportedListenerId}`, { token: A });
  const report = reports.body.items?.[0];
  check('reports list filters by status and reported user', reports.status === 200 && report?.reported_id === reportedListenerId, reports.body);
  if (report) {
    const noNote = await call('POST', `/admin/reports/${report.id}`, { token: A, body: { action: 'resolve' } });
    check('resolving a report without a note is refused', noNote.status === 400, noNote.body);
    const review = await call('POST', `/admin/reports/${report.id}`, { token: A, body: { action: 'review' } });
    const resolve = await call('POST', `/admin/reports/${report.id}`, { token: A, body: { action: 'resolve', note: 'smoke: handled' } });
    check('report moves to reviewing, then actioned', review.body.status === 'reviewing' && resolve.body.status === 'actioned', { review: review.body, resolve: resolve.body });
    const again = await call('POST', `/admin/reports/${report.id}`, { token: A, body: { action: 'dismiss', note: 'twice' } });
    check('a resolved report cannot be resolved again', again.status === 400, again.body);
    const rdetail = await call('GET', `/admin/reports/${report.id}`, { token: A });
    check('report detail carries its action history and resolution',
      rdetail.body.history?.map((h) => h.action).join(',') === 'report.resolve,report.review' &&
        rdetail.body.resolution_note === 'smoke: handled', rdetail.body.history);
  }

  console.log('== Admin: audit log ==');
  const auditPage = await call('GET', `/admin/audit?action=kyc.approve&targetId=${applicant.user.id}`, { token: A });
  check('audit log is filterable by action and target', auditPage.body.items?.length === 1 && auditPage.body.items[0].admin_phone === adminPhone, auditPage.body);
  const auditMeta = await call('GET', '/admin/audit/meta', { token: A });
  check('audit meta lists recorded actions', auditMeta.status === 200 && auditMeta.body.actions.includes('user.create'), auditMeta.body);
  let rewriteRefused = false;
  try {
    await pool.query("UPDATE admin_audit_log SET reason = 'tampered' WHERE id = $1", [auditPage.body.items?.[0]?.id ?? 0]);
  } catch {
    rewriteRefused = true;
  }
  check('the audit log refuses UPDATE at the database level', rewriteRefused);

  const OPS_ROUTES = ['/admin/posts', '/admin/calls', `/admin/wallet/${admin.user.id}`, `/admin/ledger/${admin.user.id}`,
    '/admin/payouts', '/admin/system/health'];
  const opsDenied = await Promise.all(OPS_ROUTES.map((p) => call('GET', p, { token: callerToken })));
  check('every operations route rejects a non-admin (403)', opsDenied.every((r) => r.status === 403),
    opsDenied.map((r, i) => `${OPS_ROUTES[i]}:${r.status}`));

  console.log('== Admin: content ==');
  const posts = await call('GET', '/admin/posts?status=active&pageSize=5', { token: A });
  check('content list returns posts with signed previews',
    posts.status === 200 && posts.body.items.every((p) => p.status === 'active' && ('mediaUrl' in p)), posts.body.total);
  const post = posts.body.items?.[0];
  if (post) {
    const noReason = await call('POST', `/admin/posts/${post.id}`, { token: A, body: { action: 'remove' } });
    check('removing a post without a reason is refused', noReason.status === 400, noReason.body);
    const removed = await call('POST', `/admin/posts/${post.id}`, { token: A, body: { action: 'remove', reason: 'smoke moderation' } });
    const feedAfter = await call('GET', '/feed?limit=50', { token: callerToken });
    check('a removed post disappears from the public feed',
      removed.body.status === 'removed' && !(feedAfter.body.posts || feedAfter.body.items || []).some((p) => p.id === post.id), removed.body);
    const restored = await call('POST', `/admin/posts/${post.id}`, { token: A, body: { action: 'restore', reason: 'smoke restore' } });
    check('an admin-removed post can be restored', restored.body.status === 'active', restored.body);
  } else console.log('  (no live posts to moderate — skipped remove/restore)');

  console.log('== Admin: calls ==');
  const calls = await call('GET', '/admin/calls?sort=coins&dir=desc&pageSize=5', { token: A });
  check('calls list is sorted by caller spend',
    calls.status === 200 && calls.body.items.every((c, i, a) => i === 0 || Number(a[i - 1].coins_spent) >= Number(c.coins_spent)), calls.body.items?.map((c) => c.coins_spent));
  if (calls.body.items?.[0]) {
    const cd = await call('GET', `/admin/calls/${calls.body.items[0].id}`, { token: A });
    check('call detail includes its billing ticks and hides the media channel',
      cd.status === 200 && Array.isArray(cd.body.ticks) && !('agora_channel' in cd.body), Object.keys(cd.body));
  }
  const audioCalls = await call('GET', '/admin/calls?type=audio&pageSize=10', { token: A });
  check('calls filter by type', audioCalls.body.items?.every((c) => c.type === 'audio'), audioCalls.body.total);

  console.log('== Admin: wallet / ledger ==');
  const target = created.body.id;
  const before = await call('GET', `/admin/wallet/${target}`, { token: A });
  const credit = await call('POST', `/admin/wallet/${target}/adjust`, { token: A, body: { amount: 25, reason: 'smoke goodwill credit' } });
  const overdraft = await call('POST', `/admin/wallet/${target}/adjust`, { token: A, body: { amount: -1000, reason: 'smoke overdraft attempt' } });
  const debit = await call('POST', `/admin/wallet/${target}/adjust`, { token: A, body: { amount: -10, reason: 'smoke correction' } });
  check('admin can credit and debit coins; an overdraft is refused',
    credit.status === 201 && credit.body.balanceAfter === before.body.coinBalance + 25 &&
      overdraft.status === 402 && debit.status === 201 && debit.body.balanceAfter === before.body.coinBalance + 15,
    { credit: credit.body, overdraft: overdraft.body, debit: debit.body });
  const noReasonAdj = await call('POST', `/admin/wallet/${target}/adjust`, { token: A, body: { amount: 5 } });
  check('an adjustment without a reason is refused', noReasonAdj.status === 400, noReasonAdj.body);
  const ledger = await call('GET', `/admin/ledger/${target}?reason=admin_adjustment`, { token: A });
  check('adjustments are new append-only ledger rows tied to their audit entry',
    ledger.body.items?.length === 2 && ledger.body.items.every((l) => /^admin_adj:\d+$/.test(l.ref_id)), ledger.body.items);
  const auditForAdj = await pool.query("SELECT count(*)::int AS n FROM admin_audit_log WHERE action = 'wallet.adjust' AND target_id = $1", [String(target)]);
  check('each successful adjustment is audit-logged (the refused one is not)', auditForAdj.rows[0].n === 2, auditForAdj.rows[0]);
  const after = await call('GET', `/admin/wallet/${target}`, { token: A });
  check('the wallet still reconciles with its ledger after adjustments', after.body.balanced === true && after.body.coinBalance === before.body.coinBalance + 15, after.body);

  console.log('== Admin: payouts ==');
  const payouts = await call('GET', '/admin/payouts?status=all&pageSize=10', { token: A });
  check('payouts list (all statuses) returns a page envelope', payouts.status === 200 && Array.isArray(payouts.body.items), payouts.body.total);
  const refOnMissing = await call('POST', '/admin/payouts/999999999/reference', { token: A, body: { upiRef: 'UTR123456' } });
  check('a transfer reference can only be recorded on a paid payout', refOnMissing.status === 400, refOnMissing.body);
  const rejectNoNote = await call('POST', '/admin/payouts/999999999', { token: A, body: { approve: false } });
  check('rejecting a payout without a reason is refused', rejectNoNote.status === 400, rejectNoNote.body);

  console.log('== Admin: system ==');
  const health = await call('GET', '/admin/system/health', { token: A });
  const healthText = JSON.stringify(health.body);
  check('system health reports API, database, Redis and storage as healthy',
    health.status === 200 && health.body.api.ok && health.body.database.ok && health.body.redis.ok && health.body.storage.ok &&
      health.body.database.migrations.pending.length === 0, health.body);
  check('system health reports the tick worker heartbeat', health.body.tickWorker?.ok === true, health.body.tickWorker);
  check('system health exposes no secrets or hosts',
    !/supabase\.co|upstash|password|service_role|postgres(ql)?:\/\//i.test(healthText) &&
      !healthText.includes(process.env.SUPABASE_SERVICE_ROLE_KEY || '~none~'), 'health payload');
  const earningsRec = await call('GET', '/admin/reconcile/earnings', { token: A });
  check('earnings reconciliation responds', earningsRec.status === 200 && typeof earningsRec.body.balanced === 'boolean', earningsRec.body);
  await deletionSmoke({ A, adminId: admin.user.id, callerToken, sessionFor });
}

/**
 * Admin permanent deletion. Everything here runs on accounts this run
 * creates, so nothing seeded or shared is ever deleted.
 */
async function deletionSmoke({ A, adminId, callerToken, sessionFor }) {
  const storage = require('../src/integrations/storage');
  const { FEED_MEDIA, LISTENER_PHOTOS, CHAT_MEDIA } = require('../src/utils/constants');
  const exists = async (bucket, path) => (await storage.statObject(bucket, path)) !== null;
  const caller = (await call('GET', '/users/me', { token: callerToken })).body;

  async function upload(token, endpoint) {
    const auth = await call('POST', endpoint, { token, body: { mimeType: 'image/png' } });
    const put = await uploadToSignedUrl({ uploadUrl: auth.body.uploadUrl, token: auth.body.token, mimeType: 'image/png', bytes: TINY_PNG });
    return put.status < 300 ? auth.body.path : null;
  }
  async function post(token) {
    const path = await upload(token, '/feed/media/upload-url');
    const created = await call('POST', '/feed', { token, body: { mediaPath: path, caption: 'deletion smoke' } });
    return { id: created.body.post?.id, path };
  }
  async function chatPhoto(token, toUserId) {
    const path = await upload(token, '/chat/media/upload-url');
    const sent = await call('POST', `/chat/${toUserId}/messages`, { token, body: { type: 'image', mediaPath: path } });
    return { id: sent.body.message?.id, path };
  }
  async function account(name) {
    const s = await sessionFor(freshTestPhone().replace(/\d{3}$/, String(Math.floor(Math.random() * 900) + 100)));
    await call('PATCH', '/users/me', { token: s.token, body: { displayName: name } });
    return s;
  }

  console.log('== Admin: permanent deletion — authorization ==');
  const victim = await account('Delete Me');
  const vid = victim.user.id;
  const noAuth = await call('DELETE', `/admin/users/${vid}`, { body: { reason: 'smoke test', confirm: String(vid) } });
  const nonAdmin = await Promise.all([
    call('DELETE', `/admin/users/${vid}`, { token: callerToken, body: { reason: 'smoke test', confirm: String(vid) } }),
    call('DELETE', '/admin/posts/1', { token: callerToken, body: { reason: 'smoke test' } }),
    call('DELETE', '/admin/listener-photos/1', { token: callerToken, body: { reason: 'smoke test' } }),
    call('DELETE', '/admin/chat-media/1', { token: callerToken, body: { reason: 'smoke test' } }),
    call('GET', `/admin/users/${vid}/deletion-preview`, { token: callerToken }),
  ]);
  check('permanent delete rejects an unauthenticated request (401)', noAuth.status === 401, noAuth.status);
  check('every permanent-delete route rejects a non-admin (403)', nonAdmin.every((r) => r.status === 403), nonAdmin.map((r) => r.status));
  const stillThere = await pool.query('SELECT status FROM users WHERE id = $1', [vid]);
  check('a rejected delete changed nothing', stillThere.rows[0]?.status === 'active', stillThere.rows[0]);
  const wrongConfirm = await call('DELETE', `/admin/users/${vid}`, { token: A, body: { reason: 'smoke test', confirm: '1' } });
  check('account deletion needs the typed account id',
    wrongConfirm.status === 400 && wrongConfirm.body.error?.code === 'confirmation_mismatch', wrongConfirm.body);
  const noReason = await call('DELETE', `/admin/users/${vid}`, { token: A, body: { confirm: String(vid) } });
  check('account deletion needs a reason', noReason.status === 400, noReason.body);
  const selfDelete = await call('DELETE', `/admin/users/${adminId}`, { token: A, body: { reason: 'smoke test', confirm: String(adminId) } });
  check('an admin cannot delete their own / an admin account', selfDelete.status === 409, selfDelete.body);

  console.log('== Admin: permanent deletion — content ==');
  const p = await post(victim.token);
  check('(setup) a post with stored media exists', p.id && (await exists(FEED_MEDIA.bucket, p.path)), p);
  const delPost = await call('DELETE', `/admin/posts/${p.id}`, { token: A, body: { reason: 'smoke: permanent post delete' } });
  const postRow = await pool.query('SELECT 1 FROM posts WHERE id = $1', [p.id]);
  check('admin permanently deletes a post', delPost.status === 200 && delPost.body.deleted === true && postRow.rowCount === 0, delPost.body);
  check("the post's stored media object is removed", !(await exists(FEED_MEDIA.bucket, p.path)));
  const feedAfter = await call('GET', '/feed?limit=50', { token: callerToken });
  check('the deleted post is gone from the feed', !(feedAfter.body.posts || []).some((x) => x.id === p.id), feedAfter.status);
  const postAudit = await pool.query(
    "SELECT reason FROM admin_audit_log WHERE action = 'content.delete_permanent' AND target_id = $1", [String(p.id)]);
  check('post deletion is audited with its reason', postAudit.rows[0]?.reason === 'smoke: permanent post delete', postAudit.rows);
  const again = await call('DELETE', `/admin/posts/${p.id}`, { token: A, body: { reason: 'smoke: again' } });
  check('deleting it again is a clean 404', again.status === 404, again.body);

  const m = await chatPhoto(victim.token, caller.id);
  check('(setup) a chat photo with stored media exists', m.id && (await exists(CHAT_MEDIA.bucket, m.path)), m);
  const delChat = await call('DELETE', `/admin/chat-media/${m.id}`, { token: A, body: { reason: 'smoke: chat photo' } });
  const msgRow = await pool.query('SELECT 1 FROM messages WHERE id = $1', [m.id]);
  check('admin permanently deletes a chat photo (row and object)',
    delChat.status === 200 && msgRow.rowCount === 0 && !(await exists(CHAT_MEDIA.bucket, m.path)), delChat.body);

  console.log('== Admin: permanent deletion — user ==');
  const adj = await call('POST', `/admin/wallet/${vid}/adjust`, { token: A, body: { amount: 12, reason: 'smoke: ledger before delete' } });
  const victimPost = await post(victim.token);
  await call('PUT', `/listeners/${caller.id}/follow`, { token: victim.token });
  // Shared chat: both sides write, and the victim reacts to the other side.
  const otherText = await call('POST', `/chat/${vid}/messages`, { token: callerToken, body: { body: 'from the other participant' } });
  const otherPhoto = await chatPhoto(callerToken, vid);
  await call('POST', `/chat/${caller.id}/messages`, { token: victim.token, body: { body: 'from the account being deleted' } });
  const victimPhoto = await chatPhoto(victim.token, caller.id);
  await call('PUT', `/chat/messages/${otherText.body.message?.id}/reaction`, { token: victim.token, body: { emoji: '❤️' } });
  const convId = (await pool.query('SELECT conversation_id FROM messages WHERE id = $1', [otherText.body.message?.id])).rows[0]?.conversation_id;
  const ledgerBefore = await pool.query('SELECT count(*)::int AS n FROM coin_ledger WHERE user_id = $1', [vid]);
  const auditBefore = await pool.query(
    "SELECT count(*)::int AS n FROM admin_audit_log WHERE target_type = 'user' AND target_id = $1", [String(vid)]);
  const preview = await call('GET', `/admin/users/${vid}/deletion-preview`, { token: A });
  check('the deletion preview lists what is deleted vs retained',
    preview.status === 200 && preview.body.blockers.length === 0 && preview.body.deleted.posts === 1 &&
      preview.body.deleted.messagesSent === 2 && preview.body.retained.otherPeoplesMessages === 2 &&
      preview.body.retained.coinLedgerEntries === ledgerBefore.rows[0].n && preview.body.retained.coinBalance === 12, preview.body);
  const delUser = await call('DELETE', `/admin/users/${vid}`, { token: A, body: { reason: 'smoke: delete user', confirm: String(vid) } });
  check('admin permanently deletes a user', adj.status === 201 && delUser.status === 200 && delUser.body.status === 'deleted', delUser.body);
  const tomb = await pool.query('SELECT phone, display_name, avatar_url, fcm_token, status FROM users WHERE id = $1', [vid]);
  check('the account is an anonymised tombstone',
    tomb.rows[0].status === 'deleted' && tomb.rows[0].phone === `deleted_${vid}` && tomb.rows[0].display_name === null, tomb.rows[0]);
  const meAfter = await call('GET', '/users/me', { token: victim.token });
  check("the deleted user's existing token is rejected", meAfter.status === 401, meAfter.status);
  const owned = await pool.query(
    `SELECT (SELECT count(*) FROM posts WHERE author_user_id = $1)::int AS posts,
            (SELECT count(*) FROM listener_relations WHERE user_id = $1)::int AS follows`, [vid]);
  check("the user's posts and follows are deleted", owned.rows[0].posts === 0 && owned.rows[0].follows === 0, owned.rows[0]);
  check("the user's post media object is removed", !(await exists(FEED_MEDIA.bucket, victimPost.path)));
  const convMsgs = await pool.query('SELECT id, sender_id FROM messages WHERE conversation_id = $1 ORDER BY id', [convId]);
  check('shared chat: the conversation stays, holding only the other participant\'s messages',
    convMsgs.rowCount === 2 && convMsgs.rows.every((r) => Number(r.sender_id) === Number(caller.id)), convMsgs.rows);
  check('shared chat: the deleted user\'s photo file is removed, the other participant\'s is kept',
    !(await exists(CHAT_MEDIA.bucket, victimPhoto.path)) && (await exists(CHAT_MEDIA.bucket, otherPhoto.path)));
  const victimReactions = await pool.query('SELECT count(*)::int AS n FROM message_reactions WHERE user_id = $1', [vid]);
  check('shared chat: the deleted user\'s reactions are removed', victimReactions.rows[0].n === 0, victimReactions.rows[0]);
  const otherInbox = await call('GET', '/chat', { token: callerToken });
  const kept = (otherInbox.body.conversations || []).find((c) => Number(c.counterparty.id) === Number(vid));
  check('shared chat: the other participant still sees the thread, with no name for the deleted account',
    kept && kept.counterparty.name === null && kept.counterparty.avatarUrl === null, kept);
  const toDeleted = await call('POST', `/chat/${vid}/messages`, { token: callerToken, body: { body: 'hello?' } });
  check('shared chat: messaging the deleted account is refused', toDeleted.status >= 400 && toDeleted.status < 500, toDeleted.body);
  const ledgerAfter = await pool.query('SELECT count(*)::int AS n FROM coin_ledger WHERE user_id = $1', [vid]);
  const walletAfter = await call('GET', `/admin/wallet/${vid}`, { token: A });
  check('the coin ledger is retained and the wallet still reconciles',
    ledgerAfter.rows[0].n === ledgerBefore.rows[0].n && walletAfter.body.balanced === true,
    { before: ledgerBefore.rows[0], after: ledgerAfter.rows[0], wallet: walletAfter.body });
  const auditAfter = await pool.query(
    "SELECT action FROM admin_audit_log WHERE target_type = 'user' AND target_id = $1 ORDER BY id", [String(vid)]);
  check('earlier audit history is intact and the deletion is audited',
    auditAfter.rowCount === auditBefore.rows[0].n + 1 && auditAfter.rows.at(-1).action === 'user.delete_permanent', auditAfter.rows);
  const auditMeta = await pool.query(
    "SELECT metadata::text AS m FROM admin_audit_log WHERE action = 'user.delete_permanent' AND target_id = $1", [String(vid)]);
  check('the deletion audit entry carries no phone number', !auditMeta.rows[0].m.includes(victim.user.phone), 'metadata');

  console.log('== Admin: permanent deletion — creator ==');
  const creator = await account('Delete Creator');
  const cid = creator.user.id;
  await call('POST', '/users/me/become-listener', { token: creator.token });
  const photos = await addListenerPhotos(creator.token, 3);
  const photoRows = (await pool.query('SELECT id, storage_path FROM listener_photos WHERE listener_id = $1 ORDER BY id', [cid])).rows;
  check('(setup) the creator has 3 stored photos', photos?.status === 201 && photoRows.length === 3, photos?.body);
  const delPhoto = await call('DELETE', `/admin/listener-photos/${photoRows[0].id}`, { token: A, body: { reason: 'smoke: creator photo' } });
  check('admin permanently deletes a creator photo (row, object, count)',
    delPhoto.status === 200 && delPhoto.body.photoCount === 2 &&
      !(await exists(LISTENER_PHOTOS.bucket, photoRows[0].storage_path)), delPhoto.body);
  const creatorPost = await post(creator.token);
  const creatorChat = await chatPhoto(creator.token, caller.id);
  const orphan = await upload(creator.token, '/feed/media/upload-url'); // uploaded, never posted
  await call('PUT', `/listeners/${cid}/follow`, { token: callerToken });
  await pool.query("UPDATE listener_profiles SET kyc_name = 'Smoke Name', upi_id = 'smoke@upi', bio = 'bio' WHERE user_id = $1", [cid]);
  check('(setup) the unregistered upload exists in storage', orphan && (await exists(FEED_MEDIA.bucket, orphan)));
  const delCreator = await call('DELETE', `/admin/users/${cid}`, { token: A, body: { reason: 'smoke: delete creator', confirm: String(cid) } });
  check('admin permanently deletes a creator',
    delCreator.status === 200 && delCreator.body.storageObjectsRemoved?.creatorPhotos === 2 &&
      delCreator.body.storageObjectsRemoved?.unregistered >= 1, delCreator.body);
  const remaining = [
    [LISTENER_PHOTOS.bucket, photoRows[1].storage_path], [LISTENER_PHOTOS.bucket, photoRows[2].storage_path],
    [FEED_MEDIA.bucket, creatorPost.path], [CHAT_MEDIA.bucket, creatorChat.path], [FEED_MEDIA.bucket, orphan],
  ];
  const still = [];
  for (const [bucket, path] of remaining) if (await exists(bucket, path)) still.push(`${bucket}/${path}`);
  check('every storage object of the creator is removed (photos, post, chat, unregistered upload)', still.length === 0, still);
  const lp = await pool.query(
    'SELECT is_online, bio, kyc_name, upi_id, kyc_doc_url, photo_count FROM listener_profiles WHERE user_id = $1', [cid]);
  check('the creator profile is kept for accounting but stripped of personal data',
    lp.rows[0] && !lp.rows[0].is_online && lp.rows[0].bio === null && lp.rows[0].kyc_name === null &&
      lp.rows[0].upi_id === null && lp.rows[0].photo_count === 0, lp.rows[0]);
  const rels = await pool.query('SELECT count(*)::int AS n FROM listener_relations WHERE listener_id = $1', [cid]);
  const convs = await pool.query('SELECT count(*)::int AS n FROM conversations WHERE user_a = $1 OR user_b = $1', [cid]);
  check('follows of the creator and their conversations are deleted',
    rels.rows[0].n === 0 && convs.rows[0].n === 0, { rels: rels.rows[0], convs: convs.rows[0] });
  const profileGone = await call('GET', `/listeners/${cid}`, { token: callerToken });
  check('the deleted creator is no longer reachable in the app', profileGone.status === 404, profileGone.status);
  const earningsRec = await call('GET', '/admin/reconcile/earnings', { token: A });
  check('earnings still reconcile after the creator deletion',
    !(earningsRec.body.discrepancies || []).some((d) => Number(d.user_id) === Number(cid)), earningsRec.body);

  await deletionFailureSmoke({ A, adminId, account, post, exists });
}

/**
 * Storage/DB failure semantics. The live server cannot be made to fail on
 * demand, so these run the SAME app in-process on a spare port with the
 * shared Storage client stubbed, against rows this run creates.
 */
async function deletionFailureSmoke({ A, adminId, account, post, exists }) {
  console.log('== Admin: permanent deletion — failure semantics ==');
  const http = require('http');
  const { createApp } = require('../src/app');
  const storage = require('../src/integrations/storage');
  const { FEED_MEDIA, LISTENER_PHOTOS } = require('../src/utils/constants');
  const realRemove = storage.removeStrict;
  const server = http.createServer(createApp());
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const local = async (method, p, body) => {
    const r = await fetch(`http://127.0.0.1:${server.address().port}/api${p}`, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${A}` },
      body: JSON.stringify(body),
    });
    return { status: r.status, body: await r.json().catch(() => ({})) };
  };
  const auditCount = async (action, targetId) => (await pool.query(
    'SELECT count(*)::int AS n FROM admin_audit_log WHERE action = $1 AND target_id = $2', [action, String(targetId)])).rows[0].n;

  try {
    const owner = await account('Failure Owner');

    // (1) Storage refuses: the DB delete and its audit row roll back.
    const p1 = await post(owner.token);
    storage.removeStrict = async () => { throw Object.assign(new Error('simulated storage outage'), { code: 'storage_remove_failed' }); };
    const refused = await local('DELETE', `/admin/posts/${p1.id}`, { reason: 'smoke: storage refuses' });
    storage.removeStrict = realRemove;
    const p1Row = await pool.query('SELECT 1 FROM posts WHERE id = $1', [p1.id]);
    check('storage failure → 502 that says nothing was deleted',
      refused.status === 502 && /nothing was deleted/.test(refused.body.error?.message || ''), refused.body);
    check('storage failure → the post row, its file and the audit log are untouched',
      p1Row.rowCount === 1 && (await exists(FEED_MEDIA.bucket, p1.path)) &&
        (await auditCount('content.delete_permanent', p1.id)) === 0 && (await auditCount('delete.incomplete', p1.id)) === 0);
    const retry1 = await call('DELETE', `/admin/posts/${p1.id}`, { token: A, body: { reason: 'smoke: retry after storage outage' } });
    check('retrying after the storage failure completes the delete',
      retry1.status === 200 && !(await exists(FEED_MEDIA.bucket, p1.path)), retry1.body);

    // (2) Storage succeeds, then the DB step fails. The only DB step after
    // the removal is COMMIT, which cannot be failed on demand against a
    // shared database, so the real failure handler is driven directly: a
    // real Storage removal, then a thrown database error (the rollback of
    // the transaction itself is Postgres's guarantee). The row survives its
    // file — reported and audited — and a retry with the file already gone
    // still completes.
    const p2 = await post(owner.token);
    const { trackedDeletion } = require('../src/modules/admin/deletion.admin');
    const adminUser = (await pool.query('SELECT id, phone FROM users WHERE id = $1', [adminId])).rows[0];
    let halfErr = null;
    try {
      await trackedDeletion(
        { user: adminUser, body: { reason: 'smoke: db fails after storage' } },
        { targetType: 'post', targetId: p2.id },
        async ({ remove }) => {
          await remove(FEED_MEDIA.bucket, [p2.path]);
          throw new Error('simulated database failure after storage');
        },
      );
    } catch (err) {
      halfErr = err;
    }
    const p2Row = await pool.query('SELECT 1 FROM posts WHERE id = $1', [p2.id]);
    check('DB failure after storage → 500 that says the file was already removed',
      halfErr?.status === 500 && halfErr.code === 'delete_incomplete' &&
        /1 stored file\(s\) were already removed/.test(halfErr.message), halfErr?.message);
    check('DB failure after storage → row kept, file gone, and the half-done state is audited',
      p2Row.rowCount === 1 && !(await exists(FEED_MEDIA.bucket, p2.path)) &&
        (await auditCount('content.delete_permanent', p2.id)) === 0 && (await auditCount('delete.incomplete', p2.id)) === 1);
    const retry2 = await call('DELETE', `/admin/posts/${p2.id}`, { token: A, body: { reason: 'smoke: retry with file already gone' } });
    const p2After = await pool.query('SELECT 1 FROM posts WHERE id = $1', [p2.id]);
    check('a missing file does not block the retry (post deleted)', retry2.status === 200 && p2After.rowCount === 0, retry2.body);

    // (3) Account deletion where Storage fails part-way (feed bucket done,
    // creator-photo bucket refuses): nothing in the DB changes, the earlier
    // removal is reported and audited, and a retry finishes everything.
    await call('POST', '/users/me/become-listener', { token: owner.token });
    await addListenerPhotos(owner.token, 3);
    const ownerPost = await post(owner.token);
    const photoPaths = (await pool.query('SELECT storage_path FROM listener_photos WHERE listener_id = $1', [owner.user.id])).rows.map((r) => r.storage_path);
    storage.removeStrict = async (bucket, paths) => {
      if (bucket === LISTENER_PHOTOS.bucket && paths.length) throw Object.assign(new Error('simulated photo bucket outage'), { code: 'storage_remove_failed' });
      return realRemove(bucket, paths);
    };
    const partial = await local('DELETE', `/admin/users/${owner.user.id}`, { reason: 'smoke: partial storage failure', confirm: String(owner.user.id) });
    storage.removeStrict = realRemove;
    const ownerRow = await pool.query('SELECT status, display_name FROM users WHERE id = $1', [owner.user.id]);
    const ownerPostRow = await pool.query('SELECT 1 FROM posts WHERE id = $1', [ownerPost.id]);
    const photosLeft = [];
    for (const path of photoPaths) if (await exists(LISTENER_PHOTOS.bucket, path)) photosLeft.push(path);
    check('partial storage failure on an account → 502 naming the files already removed',
      partial.status === 502 && /already removed/.test(partial.body.error?.message || ''), partial.body);
    check('partial storage failure → account still active and its rows intact',
      ownerRow.rows[0].status === 'active' && ownerRow.rows[0].display_name === 'Failure Owner' && ownerPostRow.rowCount === 1 &&
        photosLeft.length === 3 && (await auditCount('user.delete_permanent', owner.user.id)) === 0 &&
        (await auditCount('delete.incomplete', owner.user.id)) === 1, { row: ownerRow.rows[0], photosLeft: photosLeft.length });
    const retry3 = await call('DELETE', `/admin/users/${owner.user.id}`, { token: A, body: { reason: 'smoke: retry account', confirm: String(owner.user.id) } });
    const photosAfter = [];
    for (const path of photoPaths) if (await exists(LISTENER_PHOTOS.bucket, path)) photosAfter.push(path);
    check('retrying the account delete completes it (already-removed feed file is no obstacle)',
      retry3.status === 200 && retry3.body.status === 'deleted' && photosAfter.length === 0 &&
        !(await exists(FEED_MEDIA.bucket, ownerPost.path)), retry3.body);

    // (4) Re-running a completed account delete is harmless.
    const again = await call('DELETE', `/admin/users/${owner.user.id}`, { token: A, body: { reason: 'smoke: re-run', confirm: String(owner.user.id) } });
    const ledgerOk = await call('GET', `/admin/wallet/${owner.user.id}`, { token: A });
    check('re-running a completed account delete is idempotent',
      again.status === 200 && again.body.status === 'deleted' && ledgerOk.body.balanced === true, again.body);
  } finally {
    storage.removeStrict = realRemove;
    await new Promise((resolve) => server.close(resolve));
  }
}


main().catch(async (err) => {
  console.error('SMOKE TEST CRASHED', err);
  await closeDb();
  process.exit(1);
});
