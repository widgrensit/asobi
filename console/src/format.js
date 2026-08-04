// Formatting only. Nothing here decides what is shown, and nothing here
// throws: a cell that cannot be formatted renders the raw value rather than
// taking the table down with it.

export function shortId(value) {
  if (typeof value !== 'string') return '';
  return value.length > 12 ? `${value.slice(0, 8)}…${value.slice(-4)}` : value;
}

export function timestamp(value) {
  if (value === null || value === undefined || value === '') return '—';
  const date = typeof value === 'number' ? new Date(value) : new Date(String(value));
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toISOString().replace('T', ' ').replace(/\.\d+Z$/, 'Z');
}

// Relative time is what an operator is actually reading during an incident:
// "38s ago" answers the question, a wall clock makes them do arithmetic.
export function ago(value) {
  const date = typeof value === 'number' ? new Date(value) : new Date(String(value));
  if (Number.isNaN(date.getTime())) return '';
  return duration(Date.now() - date.getTime());
}

export function duration(ms) {
  if (typeof ms !== 'number' || Number.isNaN(ms)) return '—';
  const seconds = Math.round(Math.abs(ms) / 1000);
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
  return `${Math.floor(seconds / 86400)}d ${Math.floor((seconds % 86400) / 3600)}h`;
}

export function count(value) {
  return typeof value === 'number' ? value.toLocaleString('en-GB') : '—';
}

export function text(value) {
  if (value === null || value === undefined || value === '') return '—';
  return String(value);
}

export function json(value) {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

export function isEmptyObject(value) {
  return value && typeof value === 'object' && Object.keys(value).length === 0;
}
