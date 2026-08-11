// What an extension is allowed to add to this console, and what is refused.
//
// Everything here is pure: a declared registry in, a resolved one out, plus a
// list of problems. That is deliberate - this is the one place where code from
// outside this repository decides what the operator sees, so it is also the
// one place worth testing without a browser (`npm run check`).
//
// An extension's console source is compiled into this bundle by
// `rebar3 asobi console`, so it is not untrusted in the way a web page is: it
// came from the same release the node is running. It is still checked, because
// the failure this guards against is not an attack, it is a stale build - a
// manifest written against an older surface, or a screen for an extension this
// particular node does not have installed.

import { CORE_NAV, EXTENSION_SECTIONS, sortNav } from './nav.js';

// Bumped when the surface `public.js` exports changes shape in a way an
// existing extension would not survive. An extension declares the version it
// was written against and is refused rather than rendered half-working.
export const CONSOLE_API_VERSION = 1;

const NAME = /^[a-z][a-z0-9_]*$/;

// A relative path under the extension's own prefix. No scheme, no host, no
// dot segment, no leading slash: the extension names a path inside
// `/ext/<name>` and cannot address anything above it.
const PATH = /^[a-zA-Z0-9\-_/:*]*$/;

export function extensionPath(name, path) {
  const rest = String(path || '').replace(/^\/+/, '');
  return rest === '' ? `/ext/${name}` : `/ext/${name}/${rest}`;
}

// `installed` is the set of extension names /api/v1/ops/features reports, and
// `null` means it has not answered yet. Nothing renders until it has: one
// bundle serves deployments with different extension sets, so a nav item that
// appears and then vanishes is the normal case, not an error case, and it is
// worth one render's delay to never show it.
export function resolveRegistry(declared, { installed, caps } = {}) {
  const problems = [];
  const extensions = [];

  for (const entry of declared || []) {
    const problem = reject(entry, installed);
    if (problem) {
      // An extension the node does not have is not a problem worth reporting:
      // it is the mechanism working.
      if (problem.code !== 'not_installed') problems.push(problem);
      continue;
    }
    extensions.push({
      name: entry.name,
      nav: navOf(entry, caps, problems),
      routes: routesOf(entry, problems),
      slots: entry.slots && typeof entry.slots === 'object' ? entry.slots : {},
    });
  }

  return { extensions, nav: sortNav([...CORE_NAV, ...extensions.flatMap((e) => e.nav)]), problems };
}

function reject(entry, installed) {
  if (!entry || typeof entry !== 'object') return problem('', 'not_an_object', 'the default export is not an object');
  const { name, apiVersion } = entry;
  if (typeof name !== 'string' || !NAME.test(name)) {
    return problem(String(name), 'bad_name', 'name must match the extension name in info/0');
  }
  if (apiVersion !== CONSOLE_API_VERSION) {
    return problem(
      name,
      'api_version',
      `written against console API v${apiVersion}, this console is v${CONSOLE_API_VERSION}`,
    );
  }
  if (installed === null || installed === undefined) return problem(name, 'not_installed', '');
  if (!installed.includes(name)) return problem(name, 'not_installed', '');
  return null;
}

function navOf(entry, caps, problems) {
  const items = Array.isArray(entry.nav) ? entry.nav : [];
  const usable = [];
  for (const item of items) {
    if (!item || typeof item.label !== 'string' || item.label === '') {
      problems.push(problem(entry.name, 'bad_nav', 'a nav item has no label'));
      continue;
    }
    if (!PATH.test(String(item.path || ''))) {
      problems.push(problem(entry.name, 'bad_nav', `nav path ${item.path} is not a relative path`));
      continue;
    }
    // A screen behind a capability the session does not hold is not rendered
    // at all. The ops plane would refuse the call anyway; this is so an
    // operator is not offered a door that answers 403.
    if (Array.isArray(item.caps) && !item.caps.every((cap) => (caps || []).includes(cap))) continue;
    usable.push({
      path: extensionPath(entry.name, item.path),
      label: item.label,
      section: EXTENSION_SECTIONS.includes(item.section) ? item.section : 'game',
      order: Number.isFinite(item.order) ? item.order : 100,
    });
  }
  return usable;
}

function routesOf(entry, problems) {
  const routes = Array.isArray(entry.routes) ? entry.routes : [];
  const usable = [];
  for (const route of routes) {
    if (!route || typeof route.path !== 'string' || !PATH.test(route.path)) {
      problems.push(problem(entry.name, 'bad_route', `route path ${route && route.path} is not a relative path`));
      continue;
    }
    if (!route.element) {
      problems.push(problem(entry.name, 'bad_route', `route ${route.path} has no element`));
      continue;
    }
    usable.push({ path: route.path.replace(/^\/+/, ''), element: route.element });
  }
  return usable;
}

function problem(extension, code, message) {
  return { extension, code, message };
}

// Slots are the seam for adding to a screen core already owns, rather than
// adding a screen. The set is closed and each id is a promise about the shape
// of the context passed with it, so adding one is a contract change.
export const SLOTS = ['overview.stats', 'player.detail', 'player.actions', 'match.detail'];

export function slotEntries(extensions, id) {
  return (extensions || [])
    .filter((extension) => typeof extension.slots[id] === 'function')
    .map((extension) => ({ name: extension.name, Component: extension.slots[id] }));
}
