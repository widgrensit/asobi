// The guest purge, as the two pure decisions the screen makes. Both are here
// rather than inside the component because both are wrong in ways a rendering
// test would not catch, and `console/test` has no DOM.

// `inactive_for_seconds` has no server-side default, so the console offers no
// preselected one either: the operator names a window or the button stays off.
// `0` is spelled out rather than left as the empty value it looks like, because
// it is the widest possible selection and must never be reachable by accident.
export const GUEST_WINDOWS = [
  { value: '2592000', label: 'inactive over 30 days' },
  { value: '604800', label: 'inactive over 7 days' },
  { value: '86400', label: 'inactive over 24 hours' },
  { value: '3600', label: 'inactive over 1 hour' },
  { value: '0', label: 'every unclaimed guest, however recent' },
];

export function windowLabel(value) {
  const found = GUEST_WINDOWS.find((option) => option.value === String(value));
  return found ? found.label : '';
}

// What a completed purge means, and whether there is a next batch.
//
// The rule is the route's own and it is the one thing here worth getting
// right: repeat while `deleted` is above zero, NEVER until `remaining` reaches
// zero. A player who could not be erased stays unclaimed, still matches, and is
// re-selected on every call - so a loop watching `remaining` would run for
// ever against a cohort that is not shrinking.
export function purgeOutcome(summary) {
  if (!summary || summary.dry_run) return null;
  const deleted = summary.deleted || 0;
  const skipped = summary.skipped || 0;
  const failed = summary.failed || 0;
  const remaining = summary.remaining || 0;

  if (deleted > 0 && remaining > 0) {
    return {
      tone: 'good',
      again: true,
      message: `Erased ${deleted}. ${remaining} still match - count them again to take the next batch.`,
    };
  }
  if (deleted > 0) {
    return { tone: 'good', again: false, message: `Erased ${deleted}. Nothing matching is left.` };
  }
  if (failed > 0) {
    return {
      tone: 'bad',
      again: false,
      message:
        `Nothing was erased and ${failed} could not be. They are still unclaimed and still match, ` +
        'so repeating this will select them again and fail again. The reason is in the node log and the audit trail.',
    };
  }
  if (skipped > 0) {
    return {
      tone: 'warn',
      again: false,
      message: `Nothing was erased: ${skipped} were claimed while the purge ran, so they left the cohort.`,
    };
  }
  return { tone: 'warn', again: false, message: 'Nothing matched.' };
}
