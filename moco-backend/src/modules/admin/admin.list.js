'use strict';

const { z } = require('zod');

/**
 * Shared list plumbing for every admin table: one pagination shape, one
 * sorting rule, one way to build WHERE clauses — so every table behaves the
 * same in the console and none of them builds SQL from request strings.
 *
 * Pagination is page/pageSize with an exact total (admin tables show
 * "page 3 of 12"), fetched in the same query via count(*) OVER () rather than
 * a second round trip.
 */

const dateParam = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD')
  .optional();

/**
 * Builds the query-string schema for a list endpoint. `sortKeys` is the
 * whitelist of sortable columns (keys of the endpoint's sort map); anything
 * else is rejected by validation before it gets near SQL.
 */
function listSchema(sortKeys, extra = {}) {
  return z.object({
    page: z.coerce.number().int().min(1).max(10_000).default(1),
    pageSize: z.coerce.number().int().min(5).max(100).default(25),
    sort: z.enum(sortKeys).optional(),
    dir: z.enum(['asc', 'desc']).default('desc'),
    q: z.string().trim().max(80).optional(),
    from: dateParam,
    to: dateParam,
    ...extra,
  });
}

/**
 * Accumulates WHERE clauses with `?` placeholders that are renumbered to
 * $1..$n — so filters can be added conditionally without hand-tracking
 * parameter indexes.
 */
class Where {
  constructor() {
    this.clauses = [];
    this.params = [];
  }

  add(sql, ...values) {
    let rendered = sql;
    for (const value of values) {
      this.params.push(value);
      rendered = rendered.replace('?', `$${this.params.length}`);
    }
    this.clauses.push(rendered);
    return this;
  }

  /** Adds `clause` only when `value` is present (not undefined/null/''). */
  maybe(value, sql, ...values) {
    if (value === undefined || value === null || value === '') return this;
    return this.add(sql, ...(values.length ? values : [value]));
  }

  /** Inclusive calendar-date range on `column` (dates are YYYY-MM-DD, UTC). */
  dateRange(column, from, to) {
    if (from) this.add(`${column} >= ?::date`, from);
    if (to) this.add(`${column} < (?::date + 1)`, to);
    return this;
  }

  /** Appends a positional parameter (for LIMIT/OFFSET etc.) and returns its $n. */
  param(value) {
    this.params.push(value);
    return `$${this.params.length}`;
  }

  get sql() {
    return this.clauses.length ? `WHERE ${this.clauses.join(' AND ')}` : '';
  }
}

/** ORDER BY from a whitelisted map; a stable tiebreaker keeps paging deterministic. */
function orderBy(sortMap, sort, dir, fallback, tiebreak) {
  const key = sort && sortMap[sort] ? sort : fallback;
  const direction = dir === 'asc' ? 'ASC' : 'DESC';
  return `ORDER BY ${sortMap[key]} ${direction} NULLS LAST, ${tiebreak} ${direction}`;
}

/** LIMIT/OFFSET appended to `where`'s params. */
function limitOffset(where, { page, pageSize }) {
  return `LIMIT ${where.param(pageSize)} OFFSET ${where.param((page - 1) * pageSize)}`;
}

/** Standard page envelope. Rows must select `count(*) OVER () AS total_count`. */
function pageOf(rows, { page, pageSize }, mapRow = (r) => r) {
  const total = rows.length ? Number(rows[0].total_count) : 0;
  return {
    items: rows.map(({ total_count: _omit, ...rest }) => mapRow(rest)),
    page,
    pageSize,
    total,
    totalPages: Math.max(1, Math.ceil(total / pageSize)),
  };
}

/** Escapes LIKE wildcards in user search text. */
const likeTerm = (q) => `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;

module.exports = { listSchema, Where, orderBy, limitOffset, pageOf, likeTerm };
