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

// Binary units, because these are VM memory readings and erlang:memory/0
// counts bytes the machine allocated, not bytes a marketing department
// counted. One decimal above KiB - an operator wants "412.7 MiB", not
// "412.68359375 MiB" and not "413 MiB".
export function bytes(value) {
  if (typeof value !== 'number' || Number.isNaN(value)) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let n = Math.abs(value);
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit += 1;
  }
  const sign = value < 0 ? '-' : '';
  return unit === 0 ? `${sign}${n} B` : `${sign}${n.toFixed(1)} ${units[unit]}`;
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
