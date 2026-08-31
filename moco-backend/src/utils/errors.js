'use strict';

/**
 * Errors that carry an HTTP status and a stable machine-readable code. The
 * Flutter client switches on `code`, never on the message text, so messages
 * stay free to change or be localised.
 */
class AppError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.name = 'AppError';
    this.status = status;
    this.code = code;
    this.details = details;
    // Marks errors we raised deliberately, so the handler can distinguish them
    // from genuine crashes and log at the right level.
    this.expected = true;
  }
}

const badRequest = (code, message, details) => new AppError(400, code, message, details);
const unauthorized = (message = 'Authentication required') =>
  new AppError(401, 'unauthorized', message);
const forbidden = (message = 'Not allowed') => new AppError(403, 'forbidden', message);
const notFound = (resource = 'Resource') => new AppError(404, 'not_found', `${resource} not found`);
const conflict = (code, message) => new AppError(409, code, message);
const tooManyRequests = (message = 'Too many requests') =>
  new AppError(429, 'rate_limited', message);

/** Raised by the billing path when a wallet cannot fund the next minute. */
const insufficientBalance = (message = 'Not enough coins') =>
  new AppError(402, 'insufficient_balance', message);

module.exports = {
  AppError,
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  conflict,
  tooManyRequests,
  insufficientBalance,
};
