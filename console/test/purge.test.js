import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { GUEST_WINDOWS, purgeOutcome, windowLabel } from '../src/purge.js';

// The one rule worth a test: the console must offer another batch on `deleted`
// and never on `remaining`. A failed player stays unclaimed and is re-selected
// on every call, so a "keep going until remaining is 0" button would sit there
// for ever against a cohort that is not shrinking.

test('a batch that deleted something and left some offers another', () => {
  const outcome = purgeOutcome({ matched: 500, deleted: 200, skipped: 0, failed: 0, remaining: 300 });
  assert.equal(outcome.again, true);
  assert.equal(outcome.tone, 'good');
});

test('a batch that cleared the cohort does not', () => {
  const outcome = purgeOutcome({ matched: 20, deleted: 20, skipped: 0, failed: 0, remaining: 0 });
  assert.equal(outcome.again, false);
  assert.equal(outcome.tone, 'good');
});

// The loop that would never terminate. Every one of these still matches, so a
// second call selects the same rows and fails the same way.
test('a batch that deleted nothing and failed does not offer another, however much remains', () => {
  const outcome = purgeOutcome({ matched: 40, deleted: 0, skipped: 0, failed: 40, remaining: 40 });
  assert.equal(outcome.again, false);
  assert.equal(outcome.tone, 'bad');
  assert.match(outcome.message, /repeating this will select them again/);
});

// Skipped players were claimed mid-purge, so they left the set on their own.
// Nothing was erased and nothing is wrong.
test('a batch that only skipped reads as nothing to do, not as a failure', () => {
  const outcome = purgeOutcome({ matched: 3, deleted: 0, skipped: 3, failed: 0, remaining: 0 });
  assert.equal(outcome.again, false);
  assert.equal(outcome.tone, 'warn');
});

test('an empty cohort says so', () => {
  assert.equal(purgeOutcome({ matched: 0, deleted: 0, skipped: 0, failed: 0, remaining: 0 }).message, 'Nothing matched.');
});

// A preview deleted nothing by definition, so it must never render as a result.
test('a dry run is not an outcome', () => {
  assert.equal(purgeOutcome({ matched: 900, deleted: 0, skipped: 0, failed: 0, remaining: 900, dry_run: true }), null);
  assert.equal(purgeOutcome(null), null);
});

// The empty select value is "no window chosen". If it ever labelled something,
// the screen would let a purge run without one being named.
test('the empty window is not a window', () => {
  assert.equal(windowLabel(''), '');
  assert.equal(
    GUEST_WINDOWS.some((option) => option.value === ''),
    false,
  );
});

// `0` is the widest selection there is, so it has to be a deliberate choice
// with words on it rather than a falsy value that looks like "unset".
test('every unclaimed guest is a labelled choice, not the default', () => {
  assert.equal(windowLabel('0'), 'every unclaimed guest, however recent');
  assert.notEqual(GUEST_WINDOWS[0].value, '0');
});

test('every window is a non-negative whole number of seconds', () => {
  for (const option of GUEST_WINDOWS) {
    assert.match(option.value, /^\d+$/);
    assert.equal(windowLabel(option.value), option.label);
  }
});
