import { config } from './config.js';

// The console never holds the operator secret. It posts it once to
// /console/session and from then on carries an HttpOnly cookie it cannot read
// plus the CSRF token from the companion cookie it can. On the managed path a
// minted bearer token replaces both.

const CSRF_COOKIE = 'asobi_console_csrf';

// Pure so it can be tested without a browser: a cookie jar in, a value out.
export function readCookie(jar, name) {
  const match = String(jar || '').match(new RegExp(`(?:^|;\\s*)${name}=([^;]*)`));
  return match ? decodeURIComponent(match[1]) : '';
}

export function csrfToken() {
  return readCookie(typeof document === 'undefined' ? '' : document.cookie, CSRF_COOKIE);
}

export class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details || {};
  }
}

function authHeaders() {
  if (config.token) return { authorization: `Bearer ${config.token}` };
  return { 'x-csrf-token': csrfToken() };
}

async function request(url, options = {}) {
  let response;
  try {
    response = await fetch(url, {
      ...options,
      credentials: config.token ? 'omit' : 'include',
      headers: { ...authHeaders(), ...(options.headers || {}) },
    });
  } catch (cause) {
    // A network failure and a 500 are different problems and an operator
    // during an incident needs to know which one they have.
    throw new ApiError(0, 'network', 'The node did not answer. Check that it is up and reachable.');
  }
  if (response.status === 204) return null;
  const body = await response.json().catch(() => null);
  if (!response.ok) {
    // One place decides that the session is gone. Every screen then reacts
    // the same way instead of each one growing its own redirect.
    if (response.status === 401 || response.status === 403) {
      window.dispatchEvent(new CustomEvent('asobi:unauthenticated'));
    }
    const error = (body && body.error) || {};
    throw new ApiError(
      response.status,
      error.code || `http_${response.status}`,
      error.message || `The request failed with ${response.status}.`,
      error.details,
    );
  }
  return body;
}

// Only the parameters the ops plane actually accepts are ever sent. An empty
// value is dropped rather than sent blank: `?q=` and no `q` mean the same
// thing to the server, and the shorter URL is the one worth sharing.
export function searchParams(params = {}) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== '') search.set(key, String(value));
  }
  return search;
}

export function opsUrl(path, params) {
  const url = new URL(`${config.apiBase}${path}`, window.location.origin);
  url.search = searchParams(params).toString();
  return url.toString();
}

export function ops(path, params) {
  return request(opsUrl(path, params));
}

// The write half of the ops plane. Core owns three non-read routes and this
// console reaches two of them, so there is no generic verb here: a caller
// names the path it means and passes the body that route documents.
function opsWrite(path, body) {
  return request(opsUrl(path), {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

// The username echo is not a client-side nicety. The route checks it against
// the row, so a page that posts without one is answered `confirmation_required`
// - which is what makes a clickjacked POST insufficient.
export function erasePlayer(id, username) {
  return opsWrite(`/players/${encodeURIComponent(id)}/erase`, { username });
}

// `inactive_for_seconds` has no default server-side and none is invented here.
// `confirm_count` is omitted for a preview and required for the real call, so
// the two shapes are the two the route accepts and nothing in between.
export function purgeGuests({ inactiveForSeconds, confirmCount }) {
  const body = { inactive_for_seconds: inactiveForSeconds };
  if (confirmCount === undefined) return opsWrite('/players/guests/purge', { ...body, dry_run: true });
  return opsWrite('/players/guests/purge', { ...body, confirm_count: confirmCount });
}

// The installed feature set. One console bundle serves deployments that differ
// in which extensions they have, so what renders is decided by what this node
// answers here rather than by what the bundle was built with.
export function features() {
  return ops('/features');
}

// An extension's own `ops/0` action, at /api/v1/ops/ext/<extension>/<action>.
//
// Core owns that route and dispatches every declared action behind it, so
// there is nothing to register and no route to add - the same arrangement that
// already puts `rpc/0` behind one WebSocket frame type.
//
// A `get` carries its parameters in the query string and a write carries them
// as a JSON body, because that is what `asobi_ops_extension` reads in each
// case. Anything but `get` is audited by core before the handler runs, so a
// write from this console is durably attributed to the operator who made it
// whether or not the extension does anything about it.
export function opsExt(extension, action, options = {}) {
  const { method = 'get', params, body } = options;
  const path = `/ext/${encodeURIComponent(extension)}/${encodeURIComponent(action)}`;
  if (method === 'get') return ops(path, params);
  return request(opsUrl(path), {
    method: method.toUpperCase(),
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body || {}),
  });
}

export function login(secret, label) {
  return request('/console/session', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ secret, label }),
  });
}

export function whoami() {
  return request('/console/session');
}

export function logout() {
  return request('/console/session', { method: 'DELETE' });
}
