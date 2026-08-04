import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { readCookie, searchParams } from '../src/api.js';
import { ago, count, duration, shortId, text, timestamp } from '../src/format.js';

// What this covers and what it does not.
//
// Covers: the pure functions where a bug is silent - a cookie parser that
// matches the wrong cookie, a query builder that sends a parameter the ops
// plane rejects, and formatters that must never throw on a null column.
//
// Does NOT cover: rendering, routing, fetch behaviour, or anything that needs
// a DOM. There is no jsdom and no browser driver in this repo. The Erlang side
// (asobi_console_SUITE) proves the wire contract end to end; nothing here
// proves a screen draws.

test('readCookie takes the named cookie and not a suffix of another', () => {
  const jar = 'session_id=abc; asobi_console_csrf=tok-1; other=2';
  assert.equal(readCookie(jar, 'asobi_console_csrf'), 'tok-1');
  assert.equal(readCookie(jar, 'other'), '2');
  assert.equal(readCookie(jar, 'absent'), '');
});

// `asobi_console` is a prefix of `asobi_console_csrf`. Reading the session
// cookie's name must not return the CSRF token, or the two would be confused
// in exactly the direction that matters.
test('readCookie does not match a longer cookie name by prefix', () => {
  assert.equal(readCookie('asobi_console_csrf=tok-1', 'asobi_console'), '');
  assert.equal(readCookie('asobi_console=sess; asobi_console_csrf=tok', 'asobi_console'), 'sess');
});

// And not by suffix either: without the start-or-separator anchor, a cookie
// an attacker can plant as `xasobi_console=` would be read as the real one.
test('readCookie does not match a longer cookie name by suffix', () => {
  assert.equal(readCookie('xasobi_console=evil; asobi_console=real', 'asobi_console'), 'real');
});

test('readCookie survives an absent or empty jar', () => {
  assert.equal(readCookie(undefined, 'x'), '');
  assert.equal(readCookie('', 'x'), '');
});

test('readCookie decodes a percent-encoded value', () => {
  assert.equal(readCookie('t=a%2Fb%2Bc', 't'), 'a/b+c');
});

// An empty value and an absent parameter mean the same thing to the ops plane,
// and the shorter URL is the one worth pasting into an incident channel.
test('searchParams drops empty and absent values', () => {
  const search = searchParams({ q: '', sort: 'username', order: undefined, offset: 0, limit: 50 });
  assert.equal(search.toString(), 'sort=username&offset=0&limit=50');
});

test('searchParams keeps a zero and a false', () => {
  assert.equal(searchParams({ offset: 0, active: false }).toString(), 'offset=0&active=false');
});

test('searchParams escapes a value that would otherwise change the query', () => {
  assert.equal(searchParams({ q: 'a&b=c' }).toString(), 'q=a%26b%3Dc');
});

// Every ops projection can carry a null column. A formatter that throws takes
// the whole table down.
test('formatters never throw on a missing value', () => {
  for (const value of [null, undefined, '', 0, NaN, {}, []]) {
    assert.doesNotThrow(() => timestamp(value));
    assert.doesNotThrow(() => text(value));
    assert.doesNotThrow(() => count(value));
    assert.doesNotThrow(() => duration(value));
    assert.doesNotThrow(() => ago(value));
    assert.doesNotThrow(() => shortId(value));
  }
});

test('timestamp renders an unparseable value rather than hiding it', () => {
  assert.equal(timestamp('not a date'), 'not a date');
  assert.equal(timestamp(null), '—');
  assert.equal(timestamp('2026-08-04T12:00:00Z'), '2026-08-04 12:00:00Z');
});

test('timestamp accepts the epoch milliseconds the matchmaker reports', () => {
  assert.equal(timestamp(1785312000000), '2026-07-29 08:00:00Z');
});

test('duration reads at the scale an operator is asking about', () => {
  assert.equal(duration(900), '1s');
  assert.equal(duration(21400), '21s');
  assert.equal(duration(125000), '2m 5s');
  assert.equal(duration(7500000), '2h 5m');
});

test('shortId keeps both ends of a uuid so two rows are distinguishable', () => {
  const id = '0198c0de-0000-7000-8000-000000000001';
  const short = shortId(id);
  assert.ok(id.startsWith(short.slice(0, 8)));
  assert.ok(id.endsWith(short.slice(-4)));
  assert.equal(shortId('short'), 'short');
});
