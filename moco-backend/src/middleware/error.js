'use strict';

const { AppError } = require('../utils/errors');
const logger = require('../utils/logger');
const env = require('../config/env');

/** Wraps an async route handler so rejections reach the error middleware. */
const asyncHandler = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function notFoundHandler(req, res) {
  res.status(404).json({ error: { code: 'not_found', message: 'Unknown endpoint' } });
}

// eslint-disable-next-line no-unused-vars -- Express identifies error middleware by arity.
function errorHandler(err, req, res, next) {
  if (err instanceof AppError) {
    logger.debug({ code: err.code, path: req.path }, 'handled error');
    return res.status(err.status).json({
      error: { code: err.code, message: err.message, details: err.details },
    });
  }

  // Anything reaching here is unexpected: log it in full, but never leak the
  // stack or a driver message to the client.
  logger.error({ err, path: req.path, method: req.method }, 'unhandled error');
  return res.status(500).json({
    error: {
      code: 'internal_error',
      message: 'Something went wrong',
      ...(env.isProduction ? {} : { debug: err.message }),
    },
  });
}

module.exports = { asyncHandler, errorHandler, notFoundHandler };
