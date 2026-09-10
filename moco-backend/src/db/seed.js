'use strict';

const { withTransaction, close } = require('../config/db');
const logger = require('../utils/logger');
const { COIN_PACKS, KYC_STATUS, USER_ROLE } = require('../utils/constants');

/**
 * Development seed data.
 *
 * Wallet balances match the sample values used in the Claude Design screens
 * (45, 120, 350, 890 coins) so the app renders against the same numbers the
 * designs were built around.
 */

const SAMPLE_BALANCES = [45, 120, 350, 890];

const LISTENERS = [
  { name: 'Priya', gender: 'female', languages: ['hi', 'en'], bio: 'Good listener. Talk to me about anything.', rating: 4.8, calls: 214 },
  { name: 'Ananya', gender: 'female', languages: ['te', 'en'], bio: 'Here to listen, no judgement.', rating: 4.6, calls: 132 },
  { name: 'Kavya', gender: 'female', languages: ['te', 'hi', 'en'], bio: 'Late night conversations welcome.', rating: 4.9, calls: 388 },
  { name: 'Meera', gender: 'female', languages: ['hi'], bio: 'Friendly and patient.', rating: 4.4, calls: 76 },
  { name: 'Arjun', gender: 'male', languages: ['en', 'hi'], bio: 'Happy to talk about anything.', rating: 4.5, calls: 58 },
];

async function seed() {
  await withTransaction(async (client) => {
    logger.info('seeding development data');

    // Callers, one per sample wallet balance from the designs.
    for (const [index, balance] of SAMPLE_BALANCES.entries()) {
      const phone = `+9198000000${String(index + 1).padStart(2, '0')}`;
      const { rows } = await client.query(
        `INSERT INTO users (phone, display_name, language, gender, role)
         VALUES ($1, $2, 'hi', 'male', $3)
         ON CONFLICT (phone) DO UPDATE SET display_name = EXCLUDED.display_name
         RETURNING id`,
        [phone, `Test Caller ${index + 1}`, USER_ROLE.USER],
      );
      const userId = rows[0].id;

      await client.query(
        `INSERT INTO wallets (user_id, coin_balance) VALUES ($1, $2)
         ON CONFLICT (user_id) DO UPDATE SET coin_balance = EXCLUDED.coin_balance`,
        [userId, balance],
      );

      // Seeded balances still need a ledger row, or the reconciliation check
      // in /api/admin/reconcile would flag them as discrepancies.
      await client.query(
        `INSERT INTO coin_ledger (user_id, delta, reason, ref_id, balance_after)
         VALUES ($1, $2, 'bonus', 'seed', $2)`,
        [userId, balance],
      );
    }

    // Listeners, approved and ready to appear in discovery.
    for (const [index, listener] of LISTENERS.entries()) {
      const phone = `+9199000000${String(index + 1).padStart(2, '0')}`;
      const { rows } = await client.query(
        `INSERT INTO users (phone, display_name, language, gender, role)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (phone) DO UPDATE SET display_name = EXCLUDED.display_name
         RETURNING id`,
        [phone, listener.name, listener.languages[0], listener.gender, USER_ROLE.LISTENER],
      );
      const userId = rows[0].id;

      await client.query(
        `INSERT INTO listener_profiles
           (user_id, bio, languages, is_online, rating, rating_count, total_calls, kyc_status, upi_id)
         VALUES ($1, $2, $3, TRUE, $4, $5, $6, $7, $8)
         ON CONFLICT (user_id) DO UPDATE
           SET bio = EXCLUDED.bio, languages = EXCLUDED.languages,
               rating = EXCLUDED.rating, total_calls = EXCLUDED.total_calls,
               kyc_status = EXCLUDED.kyc_status`,
        [
          userId,
          listener.bio,
          listener.languages,
          listener.rating,
          Math.round(listener.calls * 0.6),
          listener.calls,
          KYC_STATUS.APPROVED,
          `${listener.name.toLowerCase()}@upi`,
        ],
      );

      await client.query(
        'INSERT INTO wallets (user_id, coin_balance) VALUES ($1, 0) ON CONFLICT DO NOTHING',
        [userId],
      );
    }
  });

  logger.info(
    { callers: SAMPLE_BALANCES.length, listeners: LISTENERS.length, packs: COIN_PACKS.length },
    'seed complete',
  );
}

if (require.main === module) {
  seed()
    .then(close)
    .catch((err) => {
      logger.error({ err }, 'seed failed');
      process.exit(1);
    });
}

module.exports = { seed };
