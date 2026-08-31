'use strict';

const crypto = require('crypto');
const env = require('../config/env');
const logger = require('../utils/logger');

/**
 * Coin-pack purchases.
 *
 * Two provider shapes are supported by design:
 *   * 'mock'  — local development, orders succeed instantly.
 *   * 'razorpay' — a UPI/card gateway for the web or sideloaded build.
 *
 * On Play Store builds the purchase itself happens through Google Play Billing
 * in the Flutter client; the server's job there is to verify the purchase token
 * and credit coins. Either way credit is applied only in the webhook/verify
 * path, never from a client claim that a payment succeeded.
 */

async function createOrder({ pack, userId }) {
  if (env.payments.provider === 'mock') {
    const orderId = `mock_${crypto.randomBytes(8).toString('hex')}`;
    logger.info({ orderId, packId: pack.id, userId }, '[dev] mock order created');
    return { orderId, amount: pack.priceInr * 100, currency: 'INR', provider: 'mock' };
  }

  if (env.payments.provider === 'razorpay') {
    const auth = Buffer.from(`${env.payments.keyId}:${env.payments.keySecret}`).toString('base64');
    const response = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: { Authorization: `Basic ${auth}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        amount: pack.priceInr * 100, // paise
        currency: 'INR',
        receipt: `u${userId}_${pack.id}_${Date.now()}`,
        notes: { userId: String(userId), packId: pack.id },
      }),
    });

    if (!response.ok) {
      const body = await response.text();
      logger.error({ status: response.status, body }, 'order creation failed');
      throw new Error('Payment gateway rejected the order');
    }

    const order = await response.json();
    return {
      orderId: order.id,
      amount: order.amount,
      currency: order.currency,
      provider: 'razorpay',
      keyId: env.payments.keyId,
    };
  }

  throw new Error(`Unknown payment provider: ${env.payments.provider}`);
}

/**
 * Verifies a gateway webhook. Returns false rather than throwing so the caller
 * can answer 200 to a forged request without leaking that it was detected.
 */
function verifyWebhook(rawBody, signature) {
  if (env.payments.provider === 'mock') return !env.isProduction;
  if (!env.payments.webhookSecret || !signature) return false;

  const expected = crypto
    .createHmac('sha256', env.payments.webhookSecret)
    .update(rawBody)
    .digest('hex');

  const a = Buffer.from(expected);
  const b = Buffer.from(String(signature));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = { createOrder, verifyWebhook };
