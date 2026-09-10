'use strict';

const { badRequest } = require('../utils/errors');

/**
 * Validates one part of the request against a zod schema and replaces it with
 * the parsed result, so handlers work with coerced, trusted values only.
 */
function validate(schema, source = 'body') {
  return (req, res, next) => {
    const result = schema.safeParse(req[source]);
    if (!result.success) {
      const details = result.error.issues.map((issue) => ({
        field: issue.path.join('.'),
        message: issue.message,
      }));
      return next(badRequest('validation_failed', 'Invalid request', details));
    }
    req[source] = result.data;
    return next();
  };
}

module.exports = { validate };
