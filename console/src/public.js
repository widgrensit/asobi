// `@asobi/console` - the whole surface an extension's console source may
// import, and the only one.
//
// This module is frozen the way the wire is frozen. Everything it re-exports
// is compiled into somebody else's release; a rename here breaks a build in a
// repository this one has never seen. Everything it does *not* re-export stays
// free to change, which is the point of having it at all rather than letting
// extensions import `./ui.jsx` directly.
//
// Adding an export is additive and cheap. Removing or changing the shape of
// one is a CONSOLE_API_VERSION bump, and `resolveRegistry` then refuses every
// extension written against the older number rather than rendering it
// half-working.
//
// Two things an extension imports from outside this module, on purpose:
//
//   * `react` - hooks and the JSX runtime. React is a stable enough contract
//     that wrapping it would be ceremony, and the workspace resolves one copy
//     for the whole composed bundle.
//   * its own CSS, as `*.module.css`. Vite scopes the class names and
//     `cssCodeSplit: false` merges every extension's styles into the one
//     stylesheet the shell links. Plain `.css` works and shares one global
//     namespace with every other extension, so it is a worse default.
//
// The CSP applies to extension code exactly as it applies to core's. No
// `style={{...}}` (there is no `style-src-attr`), no `eval`, no `new Function`,
// no dynamic `import()`.

export { CONSOLE_API_VERSION } from './registry.js';

// The ops plane. `opsExt` is how a screen reaches its own extension's `ops/0`
// actions; `ops` is for core's read routes.
export { ApiError, ops, opsExt, opsUrl } from './api.js';

// Data fetching with the staleness and paging behaviour every core list screen
// already has. An extension using these gets URL-carried filters for free.
export { useDebounced, useListParams, useOps } from './hooks.js';

export { ago, bytes, count, duration, json, shortId, text, timestamp } from './format.js';

export {
  Bool,
  DataTable,
  Detail,
  Empty,
  ErrorBanner,
  JsonBlock,
  Mono,
  Pager,
  Pill,
  Screen,
  Search,
  Select,
  Stat,
  Toolbar,
} from './ui.jsx';

// Who is looking, and what this node has. `useCapability` is what a screen
// asks before rendering something only some deployments can answer.
export { useActor, useCapability, useFeatures } from './context.js';

// Routing is re-exported rather than imported from react-router directly, so
// the router stays an implementation detail this console can replace without
// every extension in every host release having to move with it.
export { Link, NavLink, useNavigate, useParams, useSearchParams } from 'react-router-dom';
