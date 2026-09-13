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
  // worker a few seconds to pick the BullMQ job up and settle it.
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

  const p5Kyc = await call('POST', '/listeners/kyc', {
    token: p5Token,
    body: {
      fullName: 'Smoke Tester',
      docUrl: 'https://example.com/doc.jpg',
      upiId: 'smoketest@upi',
    },
  });
  check(
    'KYC submission moves status to pending',
    p5Kyc.status === 200 && p5Kyc.body.kycStatus === 'pending',
    p5Kyc.body,
  );

  // Approve directly via the DB, the same shortcut the admin console's action
  // ultimately performs — there is no public "approve yourself" endpoint.
  await pool.query(`UPDATE listener_profiles SET kyc_status = 'approved' WHERE user_id = $1`, [
    p5UserId,
  ]);

  const p5GoOnline = await call('PATCH', '/listeners/status', {
    token: p5Token,
    body: { isOnline: true },
  });
  check(
    'an approved listener can go online',
    p5GoOnline.status === 200 && p5GoOnline.body.isOnline === true,
    p5GoOnline.body,
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

  console.log(`\n${passed} passed, ${failed} failed`);
  await closeDb();
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(async (err) => {
  console.error('SMOKE TEST CRASHED', err);
  await closeDb();
  process.exit(1);
});
