/**
 * PM2 process definitions for the DigitalOcean droplet.
 *
 * The API runs in cluster mode so a restart is zero-downtime, while each
 * worker runs as a single fork. The tick worker in particular must not be
 * clustered casually: correctness does not depend on it (the per-call lock and
 * the UNIQUE(call_id, minute_index) constraint hold regardless), but a single
 * instance keeps Redis lock contention low, and its internal concurrency of 50
 * is already enough for a 2GB droplet.
 */
module.exports = {
  apps: [
    {
      name: 'moco-api',
      script: 'src/server.js',
      instances: 2,
      exec_mode: 'cluster',
      max_memory_restart: '400M',
      env: { NODE_ENV: 'production' },
      error_file: 'logs/api-error.log',
      out_file: 'logs/api-out.log',
      merge_logs: true,
      time: true,
      // Give in-flight requests a chance to finish on reload.
      kill_timeout: 10000,
      wait_ready: false,
    },
    {
      name: 'moco-tick',
      script: 'src/workers/tick.worker.js',
      instances: 1,
      exec_mode: 'fork',
      max_memory_restart: '300M',
      env: { NODE_ENV: 'production' },
      error_file: 'logs/tick-error.log',
      out_file: 'logs/tick-out.log',
      merge_logs: true,
      time: true,
      // Long kill timeout: never interrupt a tick mid-settlement.
      kill_timeout: 15000,
    },
    {
      name: 'moco-payout',
      script: 'src/workers/payout.worker.js',
      instances: 1,
      exec_mode: 'fork',
      max_memory_restart: '200M',
      env: { NODE_ENV: 'production' },
      error_file: 'logs/payout-error.log',
      out_file: 'logs/payout-out.log',
      merge_logs: true,
      time: true,
      kill_timeout: 15000,
    },
    {
      name: 'moco-notification',
      script: 'src/workers/notification.worker.js',
      instances: 1,
      exec_mode: 'fork',
      max_memory_restart: '200M',
      env: { NODE_ENV: 'production' },
      error_file: 'logs/notification-error.log',
      out_file: 'logs/notification-out.log',
      merge_logs: true,
      time: true,
    },
  ],
};
