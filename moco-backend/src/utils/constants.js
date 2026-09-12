'use strict';

/**
 * Single source of truth for Moco's economy.
 *
 * Nothing else in the codebase may hardcode a coin rate, a pack price or a
 * listener share. Billing, payouts, the API contract and the seed data all
 * read from here, so changing a rate is a one-line change with no drift.
 *
 * Money convention: 1 coin = 1 INR. All coin amounts are integers — there is
 * no such thing as a fractional coin anywhere in the system.
 */

const COIN_TO_INR = 1;

/** Call types. */
const CALL_TYPE = Object.freeze({ AUDIO: 'audio', VIDEO: 'video' });

/**
 * Per-minute rates.
 *
 * `coinsPerMinute` is what the caller is debited for each started minute.
 * `listenerCoinsPerMinute` is what the listener earns from it. The remainder
 * is the platform share (~50%, before Google Play's cut).
 */
const RATES = Object.freeze({
  [CALL_TYPE.AUDIO]: Object.freeze({
    coinsPerMinute: 6,
    listenerCoinsPerMinute: 2,
  }),
  [CALL_TYPE.VIDEO]: Object.freeze({
    coinsPerMinute: 12,
    listenerCoinsPerMinute: 4,
  }),
});

/**
 * Coin packs offered in the wallet. `bonus` coins are credited on top of
 * `coins` and are tracked in the ledger as part of the same topup row.
 */
const COIN_PACKS = Object.freeze([
  Object.freeze({ id: 'pack_49', priceInr: 49, coins: 49, bonus: 0 }),
  Object.freeze({ id: 'pack_99', priceInr: 99, coins: 99, bonus: 5 }),
  Object.freeze({ id: 'pack_299', priceInr: 299, coins: 299, bonus: 25 }),
  Object.freeze({ id: 'pack_599', priceInr: 599, coins: 599, bonus: 75 }),
  Object.freeze({ id: 'pack_999', priceInr: 999, coins: 999, bonus: 150 }),
]);

/** New users get 60 free seconds, on their first call only. */
const FREE_TRIAL_SECONDS = 60;

/** Billing cadence. The started minute is billed in full. */
const TICK_INTERVAL_SECONDS = 60;

/**
 * Warn the caller when their balance covers this many minutes or fewer, so the
 * client can raise the inline recharge overlay without ending the call.
 */
const LOW_BALANCE_WARNING_MINUTES = 1;

/** Redis key shapes and the TTLs that keep stale call state from lingering. */
const REDIS = Object.freeze({
  callStateKey: (callId) => `call:${callId}`,
  callLockKey: (callId) => `call:${callId}:lock`,
  presenceKey: (userId) => `presence:${userId}`,
  /** A per-call lock is held only for the length of one tick. */
  lockTtlMs: 10_000,
  /** Live call state outlives the call itself just long enough to settle it. */
  callStateTtlSeconds: 6 * 60 * 60,
  presenceTtlSeconds: 90,
});

// BullMQ rejects ':' in queue names (it uses ':' as its own key separator).
const BULL_QUEUES = Object.freeze({
  TICK: 'moco-tick',
  PAYOUT: 'moco-payout',
  NOTIFICATION: 'moco-notification',
});

/** Enum values that mirror the Postgres enums in the migrations. */
const USER_ROLE = Object.freeze({ USER: 'user', LISTENER: 'listener', BOTH: 'both' });
const USER_STATUS = Object.freeze({ ACTIVE: 'active', SUSPENDED: 'suspended', DELETED: 'deleted' });
const CALL_STATUS = Object.freeze({
  RINGING: 'ringing',
  ACTIVE: 'active',
  ENDED: 'ended',
  FAILED: 'failed',
});
const CALL_END_REASON = Object.freeze({
  CALLER_HANGUP: 'caller_hangup',
  LISTENER_HANGUP: 'listener_hangup',
  INSUFFICIENT_BALANCE: 'insufficient_balance',
  DISCONNECT: 'disconnect',
  REJECTED: 'rejected',
  TIMEOUT: 'timeout',
  ADMIN: 'admin',
});
const LEDGER_REASON = Object.freeze({
  TOPUP: 'topup',
  CALL_DEBIT: 'call_debit',
  REFUND: 'refund',
  BONUS: 'bonus',
});
const EARNING_REASON = Object.freeze({ CALL_CREDIT: 'call_credit', PAYOUT: 'payout' });
const KYC_STATUS = Object.freeze({
  UNSUBMITTED: 'unsubmitted',
  PENDING: 'pending',
  APPROVED: 'approved',
  REJECTED: 'rejected',
});
const PAYOUT_STATUS = Object.freeze({
  REQUESTED: 'requested',
  APPROVED: 'approved',
  PAID: 'paid',
  REJECTED: 'rejected',
});

/** Real-time event names shared with the Flutter client. */
const WS_EVENTS = Object.freeze({
  TICK: 'call:tick',
  LOW_BALANCE: 'call:low_balance',
  FORCED_END: 'call:forced_end',
  INCOMING_CALL: 'call:incoming',
  CALL_ACCEPTED: 'call:accepted',
  CALL_ENDED: 'call:ended',
  PRESENCE: 'listener:presence',
  CHAT_MESSAGE: 'chat:message',
  CHAT_REACTION: 'chat:reaction',
});

/** Minimum a listener must have accrued before requesting a withdrawal. */
const MIN_PAYOUT_INR = 100;

/** Chat message content types. Mirrors the `message_type` Postgres enum. */
const MESSAGE_TYPE = Object.freeze({ TEXT: 'text', IMAGE: 'image' });

/** Server-side limits for a photo message upload. Enforced again on the
 * upload-authorization endpoint, never trusted from the client alone. */
const CHAT_MEDIA = Object.freeze({
  maxBytes: 8 * 1024 * 1024,
  allowedMimeTypes: Object.freeze(['image/jpeg', 'image/png', 'image/webp']),
  bucket: 'chat-media',
});

/** Feed post media types. Mirrors the `post_media_type` Postgres enum. */
const POST_MEDIA_TYPE = Object.freeze({ IMAGE: 'image', VIDEO: 'video' });

/** Feed post lifecycle. Mirrors the `post_status` Postgres enum. A removed
 * post is soft-deleted: it stops being served but its row survives so a
 * report filed against it still resolves to something. */
const POST_STATUS = Object.freeze({ ACTIVE: 'active', REMOVED: 'removed' });

/**
 * Server-side limits for feed media, enforced on the upload-authorization
 * endpoint — the MIME type decides which bucket path and which size cap
 * apply, so a client cannot declare "image" and upload a 400MB video.
 *
 * Sizes are deliberately modest: the target market is India on mid-range
 * Android over mobile data, where a 60MB upload is a real cost to the poster
 * and a real wait to every viewer. `maxVideoSeconds` matches the approved
 * "short video" product decision and is advertised to the client so it can
 * reject an over-long clip before spending the upload.
 */
const FEED_MEDIA = Object.freeze({
  bucket: 'feed-media',
  allowedImageMimeTypes: Object.freeze(['image/jpeg', 'image/png', 'image/webp']),
  allowedVideoMimeTypes: Object.freeze(['video/mp4', 'video/quicktime']),
  maxImageBytes: 8 * 1024 * 1024,
  maxVideoBytes: 64 * 1024 * 1024,
  maxVideoSeconds: 60,
  maxCaptionLength: 500,
  /**
   * Signed view URLs last an hour. Long enough that a user scrolling a feed
   * page never watches a URL expire mid-view, short enough that a leaked URL
   * is not a durable public link to a private bucket.
   */
  viewUrlSeconds: 3600,
});

/** Every MIME type the feed accepts, in one list for schema validation. */
const FEED_MEDIA_MIME_TYPES = Object.freeze([
  ...FEED_MEDIA.allowedImageMimeTypes,
  ...FEED_MEDIA.allowedVideoMimeTypes,
]);

/**
 * The post media type a MIME type maps to, or null if it is not accepted.
 * Single source of truth for that mapping — the upload endpoint and the
 * storage path builder must never disagree about it.
 */
function postMediaTypeForMime(mimeType) {
  if (FEED_MEDIA.allowedImageMimeTypes.includes(mimeType)) return POST_MEDIA_TYPE.IMAGE;
  if (FEED_MEDIA.allowedVideoMimeTypes.includes(mimeType)) return POST_MEDIA_TYPE.VIDEO;
  return null;
}

/** Byte cap for a feed media type. */
function feedMaxBytesFor(mediaType) {
  return mediaType === POST_MEDIA_TYPE.VIDEO ? FEED_MEDIA.maxVideoBytes : FEED_MEDIA.maxImageBytes;
}

/**
 * Rate for a call type, as an object. Throws rather than returning a default:
 * a bad call type must never silently bill at the wrong rate.
 */
function rateFor(callType) {
  const rate = RATES[callType];
  if (!rate) throw new Error(`Unknown call type: ${callType}`);
  return rate;
}

/** Coins the caller pays per minute for `callType`. */
function coinsPerMinute(callType) {
  return rateFor(callType).coinsPerMinute;
}

/** Coins the listener earns per minute for `callType`. */
function listenerSharePerMinute(callType) {
  return rateFor(callType).listenerCoinsPerMinute;
}

/** Coins the platform keeps per minute for `callType`. */
function platformSharePerMinute(callType) {
  const rate = rateFor(callType);
  return rate.coinsPerMinute - rate.listenerCoinsPerMinute;
}

/** Whole minutes a balance can fund at `callType`'s rate. */
function minutesAffordable(balance, callType) {
  return Math.floor(balance / coinsPerMinute(callType));
}

/** A call may only connect if the caller can fund at least one full minute. */
function canAffordCall(balance, callType) {
  return balance >= coinsPerMinute(callType);
}

/** Look up a coin pack by id, or undefined if it is not on offer. */
function findCoinPack(packId) {
  return COIN_PACKS.find((pack) => pack.id === packId);
}

/** Total coins credited by a pack, bonus included. */
function packTotalCoins(pack) {
  return pack.coins + pack.bonus;
}

module.exports = {
  COIN_TO_INR,
  CALL_TYPE,
  RATES,
  COIN_PACKS,
  FREE_TRIAL_SECONDS,
  TICK_INTERVAL_SECONDS,
  LOW_BALANCE_WARNING_MINUTES,
  REDIS,
  BULL_QUEUES,
  USER_ROLE,
  USER_STATUS,
  CALL_STATUS,
  CALL_END_REASON,
  LEDGER_REASON,
  EARNING_REASON,
  KYC_STATUS,
  PAYOUT_STATUS,
  WS_EVENTS,
  MIN_PAYOUT_INR,
  MESSAGE_TYPE,
  CHAT_MEDIA,
  POST_MEDIA_TYPE,
  POST_STATUS,
  FEED_MEDIA,
  FEED_MEDIA_MIME_TYPES,
  postMediaTypeForMime,
  feedMaxBytesFor,
  rateFor,
  coinsPerMinute,
  listenerSharePerMinute,
  platformSharePerMinute,
  minutesAffordable,
  canAffordCall,
  findCoinPack,
  packTotalCoins,
};
