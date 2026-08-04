// Runtime configuration, read from the meta tags the shell renders.
//
// The API base is configuration and never a compile-time constant: one bundle
// serves a self-hosted node, where the ops API is same-origin, and a managed
// environment, where the browser is handed an environment base URL by the
// control plane. Baking either in would make two bundles out of one.

// Guarded so this module can be imported outside a browser - `npm run check`
// exercises the pure helpers in api.js, which import it.
function meta(name) {
  if (typeof document === 'undefined') return '';
  const el = document.querySelector(`meta[name="${name}"]`);
  return el ? el.getAttribute('content') || '' : '';
}

const base = meta('asobi-api-base');

// A token is present only when the host that served this page minted one -
// the managed-cloud path, where the control plane checks ownership and issues
// a short-lived environment-scoped token. asobi itself never emits it: a
// self-hosted node authenticates the console with a session cookie, so the
// page holds no credential that outlives it.
const token = meta('asobi-auth-token');

export const config = {
  apiBase: `${base}/api/v1/ops`,
  nodeVersion: meta('asobi-node-version') || 'unknown',
  sameOrigin: base === '',
  token,
};
