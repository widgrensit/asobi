import { useEffect, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { count, json, text } from './format.js';

export function ErrorBanner({ error, onRetry }) {
  if (!error) return null;
  const details = error.details && Object.keys(error.details).length > 0;
  return (
    <div className="banner banner-error" role="alert">
      <div className="banner-head">
        <code className="code">{error.code}</code>
        <span>{error.message}</span>
        {onRetry ? (
          <button type="button" className="btn btn-quiet" onClick={onRetry}>
            Retry
          </button>
        ) : null}
      </div>
      {details ? <pre className="pre">{json(error.details)}</pre> : null}
    </div>
  );
}

export function Empty({ children }) {
  return <div className="empty">{children}</div>;
}

// The result of something that already happened, which is not an error and so
// must not look like one. `bad` here means "the action did not do what you
// asked", not "the request failed" - that is still `ErrorBanner`.
export function Note({ tone, children }) {
  return (
    <div className={`banner banner-${tone || 'warn'}`} role="status">
      {children}
    </div>
  );
}

// Everything irreversible on a screen, in one place, below everything else,
// and only rendered for an actor holding the class. Collapsed until asked for:
// the erase controls sit on a screen an operator opens to read, and a live
// confirm field next to a player's record is one stray Enter from a deletion.
export function Danger({ title, summary, children }) {
  const [open, setOpen] = useState(false);
  return (
    <section className="card card-danger">
      <h2 className="card-title">{title}</h2>
      <p className="card-note">{summary}</p>
      {open ? (
        children
      ) : (
        <div className="chips">
          <button type="button" className="btn btn-danger" onClick={() => setOpen(true)}>
            {title}…
          </button>
        </div>
      )}
    </section>
  );
}

// The search box focuses on `/` and clears on Escape. Both are muscle memory
// and both matter more than they look when the operator is typing a player
// name off a support ticket.
export function Search({ value, onChange, placeholder }) {
  const input = useRef(null);
  useEffect(() => {
    function onKey(event) {
      const tag = event.target.tagName;
      if (event.key === '/' && tag !== 'INPUT' && tag !== 'TEXTAREA') {
        event.preventDefault();
        input.current?.focus();
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  return (
    <input
      ref={input}
      className="input"
      type="search"
      value={value}
      spellCheck="false"
      autoComplete="off"
      placeholder={placeholder || 'Search  ( / )'}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={(event) => {
        if (event.key === 'Escape') onChange('');
      }}
    />
  );
}

export function Select({ label, value, onChange, options }) {
  return (
    <label className="select">
      <span className="select-label">{label}</span>
      <select className="input" value={value} onChange={(event) => onChange(event.target.value)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  );
}

export function Toolbar({ children, right }) {
  return (
    <div className="toolbar">
      <div className="toolbar-left">{children}</div>
      <div className="toolbar-right">{right}</div>
    </div>
  );
}

// `total` comes from the envelope, so the pager states the size of the set
// rather than guessing from whether the page came back full.
export function Pager({ page, onOffset, loading }) {
  if (!page) return null;
  const { limit, offset, total } = page;
  const from = total === 0 ? 0 : offset + 1;
  const to = Math.min(offset + limit, total);
  return (
    <div className="pager">
      <span className="pager-range">
        {count(from)}–{count(to)} of {count(total)}
        {loading ? <span className="pager-loading"> · loading</span> : null}
      </span>
      <span className="pager-buttons">
        <button
          type="button"
          className="btn btn-quiet"
          disabled={offset <= 0}
          onClick={() => onOffset(Math.max(0, offset - limit))}
        >
          ← Prev
        </button>
        <button
          type="button"
          className="btn btn-quiet"
          disabled={offset + limit >= total}
          onClick={() => onOffset(offset + limit)}
        >
          Next →
        </button>
      </span>
    </div>
  );
}

// Sorting is server-side and the header only asks. A column whose `sort` key
// is absent is not clickable, because the ops plane answers 400 for a field
// it does not allow and a dead header is better than a rejected request.
export function DataTable({ columns, rows, sort, order, onSort, loading, empty, rowKey, rowLink }) {
  if (!rows) return <div className="table-skeleton" aria-hidden="true" />;
  if (rows.length === 0) return <Empty>{empty || 'No rows.'}</Empty>;

  return (
    <div className="table-wrap">
      <table className={loading ? 'table table-stale' : 'table'}>
        <thead>
          <tr>
            {columns.map((column) => (
              <th
                key={column.key}
                className={column.numeric ? 'num' : undefined}
                aria-sort={sort === column.sort ? (order === 'desc' ? 'descending' : 'ascending') : undefined}
              >
                {column.sort ? (
                  <button
                    type="button"
                    className="th-sort"
                    onClick={() => onSort(column.sort)}
                    title={`Sort by ${column.label}`}
                  >
                    {column.label}
                    <span className="th-arrow">
                      {sort === column.sort ? (order === 'desc' ? '↓' : '↑') : ''}
                    </span>
                  </button>
                ) : (
                  column.label
                )}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const key = rowKey ? rowKey(row) : row.id;
            const to = rowLink ? rowLink(row) : null;
            return (
              <tr key={key}>
                {columns.map((column, index) => (
                  <td key={column.key} className={column.numeric ? 'num' : undefined}>
                    {index === 0 && to ? (
                      <Link className="row-link" to={to}>
                        {column.render(row)}
                      </Link>
                    ) : (
                      column.render(row)
                    )}
                  </td>
                ))}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function Mono({ children, title }) {
  return (
    <code className="code" title={title || (typeof children === 'string' ? children : undefined)}>
      {children}
    </code>
  );
}

export function Pill({ tone, children }) {
  return <span className={`pill pill-${tone || 'neutral'}`}>{children}</span>;
}

export function Bool({ value, yes, no }) {
  return <Pill tone={value ? 'good' : 'muted'}>{value ? yes || 'yes' : no || 'no'}</Pill>;
}

export function Stat({ label, value, hint }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
      {hint ? <div className="stat-hint">{hint}</div> : null}
    </div>
  );
}

export function Detail({ fields }) {
  return (
    <dl className="detail">
      {fields.map(([label, value]) => (
        <div className="detail-row" key={label}>
          <dt>{label}</dt>
          <dd>{value === undefined || value === null ? text(value) : value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function JsonBlock({ label, value }) {
  if (value === undefined || value === null) return null;
  return (
    <section className="card">
      <h2 className="card-title">{label}</h2>
      <pre className="pre">{json(value)}</pre>
    </section>
  );
}

export function Screen({ title, subtitle, children, actions }) {
  return (
    <section className="screen">
      <header className="screen-head">
        <div>
          <h1 className="screen-title">{title}</h1>
          {subtitle ? <p className="screen-sub">{subtitle}</p> : null}
        </div>
        <div className="screen-actions">{actions}</div>
      </header>
      {children}
    </section>
  );
}
