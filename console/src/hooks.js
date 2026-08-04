import { useCallback, useEffect, useRef, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { ops } from './api.js';

const DEFAULT_LIMIT = 50;

// List state lives in the URL, so a link to the thing an operator is looking
// at carries the filter, the sort and the page with it. Pasting one into an
// incident channel is the point.
export function useListParams(defaults = {}) {
  const [params, setParams] = useSearchParams();
  const read = (key, fallback) => params.get(key) ?? defaults[key] ?? fallback;

  const set = useCallback(
    (patch) => {
      setParams(
        (previous) => {
          const next = new URLSearchParams(previous);
          for (const [key, value] of Object.entries(patch)) {
            if (value === '' || value === undefined || value === null) next.delete(key);
            else next.set(key, String(value));
          }
          // Any change to what is being asked for resets the window. Landing
          // on page 7 of a freshly filtered set is never what was meant.
          if (!('offset' in patch)) next.delete('offset');
          return next;
        },
        { replace: true },
      );
    },
    [setParams],
  );

  return {
    q: read('q', ''),
    sort: read('sort', ''),
    order: read('order', ''),
    limit: Number(read('limit', DEFAULT_LIMIT)),
    offset: Number(read('offset', 0)),
    filters: params,
    set,
  };
}

// Keeps the previous rows on screen while the next page loads. A table that
// blanks on every keystroke is unusable at the exact moment it matters.
export function useOps(path, params, options = {}) {
  const { poll = 0, enabled = true } = options;
  const [state, setState] = useState({ data: null, error: null, loading: enabled });
  const [tick, setTick] = useState(0);
  const key = JSON.stringify([path, params]);
  const latest = useRef(0);

  const refresh = useCallback(() => setTick((value) => value + 1), []);

  useEffect(() => {
    if (!enabled) return undefined;
    const request = ++latest.current;
    let live = true;
    setState((previous) => ({ ...previous, loading: true }));
    ops(path, params)
      .then((body) => {
        if (live && request === latest.current) setState({ data: body, error: null, loading: false });
      })
      .catch((error) => {
        if (live && request === latest.current) {
          setState((previous) => ({ data: previous.data, error, loading: false }));
        }
      });
    return () => {
      live = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, tick, enabled]);

  useEffect(() => {
    if (!poll || !enabled) return undefined;
    const timer = setInterval(refresh, poll);
    return () => clearInterval(timer);
  }, [poll, enabled, refresh]);

  return { ...state, refresh };
}

export function useDebounced(value, delay = 250) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);
  return debounced;
}
