import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { CONSOLE_API_VERSION, extensionPath, resolveRegistry, slotEntries } from '../src/registry.js';
import { CORE_NAV, sortNav } from '../src/nav.js';

// This is the seam where code from outside this repository decides what an
// operator sees, and it is pure, so it is the part of the extension mechanism
// worth proving without a browser. Rendering is not covered here and is not
// covered anywhere; see pure.test.js for why.

const panel = () => null;

function quests(overrides = {}) {
  return {
    name: 'quests',
    apiVersion: CONSOLE_API_VERSION,
    nav: [{ path: '', label: 'Quests', section: 'game', order: 10 }],
    routes: [{ path: '', element: 'screen' }],
    ...overrides,
  };
}

test('an installed extension contributes nav and routes', () => {
  const { extensions, nav, problems } = resolveRegistry([quests()], { installed: ['quests'], caps: ['read'] });
  assert.equal(problems.length, 0);
  assert.equal(extensions.length, 1);
  assert.deepEqual(extensions[0].routes, [{ path: '', element: 'screen' }]);
  assert.ok(nav.some((item) => item.path === '/ext/quests' && item.label === 'Quests'));
});

// One composed bundle serves several deployments. A screen for an extension
// this node does not have is the normal case, not a defect, so it is dropped
// silently - reporting it would make every staging console noisy.
test('an extension the node does not report is dropped without a problem', () => {
  const { extensions, problems } = resolveRegistry([quests()], { installed: ['clans'], caps: [] });
  assert.equal(extensions.length, 0);
  assert.equal(problems.length, 0);
});

test('nothing renders until features has answered', () => {
  const { extensions } = resolveRegistry([quests()], { installed: null, caps: [] });
  assert.equal(extensions.length, 0);
});

// A stale build is the failure this guards: an extension compiled against an
// older surface would render half-working, which is worse than not at all.
test('a mismatched api version is refused and reported', () => {
  const { extensions, problems } = resolveRegistry([quests({ apiVersion: 99 })], {
    installed: ['quests'],
    caps: [],
  });
  assert.equal(extensions.length, 0);
  assert.equal(problems.length, 1);
  assert.equal(problems[0].code, 'api_version');
});

test('a manifest that is not an object, or has no usable name, is refused', () => {
  const { extensions, problems } = resolveRegistry([null, { name: 'Bad Name', apiVersion: CONSOLE_API_VERSION }], {
    installed: ['quests'],
    caps: [],
  });
  assert.equal(extensions.length, 0);
  assert.deepEqual(
    problems.map((problem) => problem.code),
    ['not_an_object', 'bad_name'],
  );
});

// The extension names a path inside its own prefix. Anything that could
// address something above it is refused rather than normalised, because a
// normaliser is a thing to get wrong.
test('a nav or route path that escapes the extension prefix is refused', () => {
  const escaping = quests({
    nav: [{ path: '../players', label: 'Players', section: 'core', order: -1 }],
    routes: [{ path: '../../etc', element: 'x' }],
  });
  const { extensions, problems } = resolveRegistry([escaping], { installed: ['quests'], caps: [] });
  assert.equal(extensions[0].nav.length, 0);
  assert.equal(extensions[0].routes.length, 0);
  assert.deepEqual(
    problems.map((problem) => problem.code),
    ['bad_nav', 'bad_route'],
  );
});

test('paths are joined under the extension prefix', () => {
  assert.equal(extensionPath('quests', ''), '/ext/quests');
  assert.equal(extensionPath('quests', 'define'), '/ext/quests/define');
  assert.equal(extensionPath('quests', '/define'), '/ext/quests/define');
  assert.equal(extensionPath('quests', ':id'), '/ext/quests/:id');
});

// The ops plane would refuse the call anyway. This is so an operator is not
// offered a door that answers 403.
test('a nav item is hidden when the session lacks the capability it declares', () => {
  const gated = quests({ nav: [{ path: '', label: 'Quests', caps: ['erasure'] }] });
  const without = resolveRegistry([gated], { installed: ['quests'], caps: ['read', 'config'] });
  assert.equal(without.extensions[0].nav.length, 0);
  const with_ = resolveRegistry([gated], { installed: ['quests'], caps: ['read', 'erasure'] });
  assert.equal(with_.extensions[0].nav.length, 1);
});

// An extension cannot place itself above the screens an operator navigates by
// muscle memory, whatever order it declares.
test('an unknown section falls back to game, below every core screen', () => {
  const sneaky = quests({ nav: [{ path: '', label: 'Quests', section: 'core ', order: -1000 }] });
  const { nav } = resolveRegistry([sneaky], { installed: ['quests'], caps: [] });
  assert.equal(nav[0].path, '/');
  assert.equal(nav[nav.length - 1].path, '/ext/quests');
});

// The section core's own screens are in, spelled exactly. The case above only
// ever exercised the fallback, because 'core ' is not a section at all.
test('core itself is not a section an extension may name', () => {
  const sneaky = quests({ nav: [{ path: '', label: 'Aaa', section: 'core', order: -1000 }] });
  const { nav } = resolveRegistry([sneaky], { installed: ['quests'], caps: [] });
  assert.equal(nav[0].path, '/');
  assert.equal(nav[nav.length - 1].path, '/ext/quests');
});

test('ties within a section break on label, not on release link order', () => {
  const items = [
    { path: '/b', label: 'Beta', section: 'game', order: 10 },
    { path: '/a', label: 'Alpha', section: 'game', order: 10 },
  ];
  assert.deepEqual(
    sortNav(items).map((item) => item.label),
    ['Alpha', 'Beta'],
  );
});

test('core nav is unchanged by an empty registry', () => {
  const { nav } = resolveRegistry([], { installed: [], caps: [] });
  assert.deepEqual(nav, sortNav(CORE_NAV));
});

test('slotEntries returns only extensions that filled the named slot', () => {
  const { extensions } = resolveRegistry(
    [quests({ slots: { 'player.detail': panel, 'match.detail': 'not a component' } })],
    { installed: ['quests'], caps: [] },
  );
  assert.deepEqual(
    slotEntries(extensions, 'player.detail').map((entry) => entry.name),
    ['quests'],
  );
  assert.deepEqual(slotEntries(extensions, 'match.detail'), []);
  assert.deepEqual(slotEntries(extensions, 'overview.stats'), []);
});
