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
