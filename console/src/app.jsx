import { Fragment, useCallback, useEffect, useMemo, useState } from 'react';
import { HashRouter, NavLink, Route, Routes } from 'react-router-dom';
import { config } from './config.js';
import { features as readFeatures, logout, whoami } from './api.js';
import { ConsoleContext, installedNames } from './context.js';
import { extensions as declared } from './registry.generated.js';
import { resolveRegistry } from './registry.js';
import { SECTIONS } from './nav.js';
import { ExtensionRoutes } from './extensions.jsx';
import {
  Chat,
  ChatMessages,
  Economy,
  EconomyItem,
  Leaderboards,
  LeaderboardEntries,
  Login,
  MatchDetail,
  Matches,
  Matchmaker,
  NotFound,
  Notifications,
  Overview,
  PlayerDetail,
  Players,
  TournamentDetail,
  Tournaments,
} from './screens.jsx';

// Hash routing, not history routing. Deep links work, and the server needs no
// catch-all route to serve the shell under - which matters more than usual
// here, because a wildcard path segment is exactly the route form that has a
// traversal defect in Nova's own static handler.
export default function App() {
  const [actor, setActor] = useState(null);
  const [checked, setChecked] = useState(false);
  const [features, setFeatures] = useState(null);

  const signOut = useCallback(() => {
    setActor(null);
    setFeatures(null);
    logout().catch(() => {});
  }, []);

  useEffect(() => {
    whoami()
      .then((body) => setActor(body.data))
      .catch(() => setActor(null))
      .finally(() => setChecked(true));
  }, []);

  // Read once per session rather than polled: the installed set is fixed for
  // the lifetime of a node, and a console that outlives a deploy is a console
  // whose page needs reloading anyway.
  useEffect(() => {
    if (!actor) return;
    readFeatures()
      .then((body) => setFeatures(body.data))
      .catch(() => setFeatures(null));
  }, [actor]);

  useEffect(() => {
    const onLost = () => setActor(null);
    window.addEventListener('asobi:unauthenticated', onLost);
    return () => window.removeEventListener('asobi:unauthenticated', onLost);
  }, []);

  const registry = useMemo(
    () => resolveRegistry(declared, { installed: installedNames(features), caps: actor && actor.caps }),
    [features, actor],
  );

  // A refused extension means somebody's build is stale - a console composed
  // against a different asobi, or an extension dropped from the release and
  // left in the bundle. There is no operator action for it, so it is logged
  // rather than rendered.
  useEffect(() => {
    for (const problem of registry.problems) {
      // eslint-disable-next-line no-console
      console.warn(`asobi console: extension ${problem.extension} refused (${problem.code}): ${problem.message}`);
    }
  }, [registry.problems]);

  const context = useMemo(
    () => ({ actor, features, extensions: registry.extensions }),
    [actor, features, registry.extensions],
  );

  if (!checked) return <div className="boot" aria-busy="true" />;
  if (!actor) return <Login onSignedIn={setActor} />;

  return (
    <ConsoleContext.Provider value={context}>
      <HashRouter>
        <div className="shell">
          <nav className="nav">
            {/* The label is the first thing in the shell, and production is
                coloured, because an operator with several consoles open picks a
                tab before they read anything else in it. */}
            <div className="brand">
              asobi ops
              {config.label ? (
                <span className={config.production ? 'target target-prod' : 'target'}>{config.label}</span>
              ) : null}
            </div>
            {/* One list, not one per section. `.nav-list` carries `flex: 1` so
                it fills the column and holds the footer at the bottom, and
                several of them would share that space between themselves
                instead. Sections are a rule about order and a hairline, not a
                second element. */}
            <ul className="nav-list">
              {registry.nav.map((item, index) => (
                <Fragment key={item.path}>
                  {index > 0 && item.section !== registry.nav[index - 1].section ? (
                    <li className="nav-gap" aria-hidden="true" />
                  ) : null}
                  <li>
                    <NavLink
                      to={item.path}
                      end={item.path === '/'}
                      className={({ isActive }) => (isActive ? 'nav-link on' : 'nav-link')}
                    >
                      {item.label}
                    </NavLink>
                  </li>
                </Fragment>
              ))}
            </ul>
            <div className="nav-foot">
              <div className="who">
                <span className="who-name">{actor.display}</span>
                <span className="who-source">
                  {actor.source}
                  {actor.attested ? '' : ' · unattested'}
                </span>
              </div>
              <button type="button" className="btn btn-quiet" onClick={signOut}>
                Sign out
              </button>
              <div className="who-node">node {config.nodeVersion}</div>
            </div>
          </nav>
          <main className="main">
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/players" element={<Players />} />
              <Route path="/players/:id" element={<PlayerDetail />} />
              <Route path="/matches" element={<Matches />} />
              <Route path="/matches/:id" element={<MatchDetail />} />
              <Route path="/matchmaker" element={<Matchmaker />} />
              <Route path="/leaderboards" element={<Leaderboards />} />
              <Route path="/leaderboards/:id" element={<LeaderboardEntries />} />
              <Route path="/economy" element={<Economy />} />
              <Route path="/economy/items/:id" element={<EconomyItem />} />
              <Route path="/chat" element={<Chat />} />
              <Route path="/chat/:id" element={<ChatMessages />} />
              <Route path="/tournaments" element={<Tournaments />} />
              <Route path="/tournaments/:id" element={<TournamentDetail />} />
              <Route path="/notifications" element={<Notifications />} />
              {/* Everything an installed extension contributes, under one
                  prefix it cannot escape. See extensions.jsx. */}
              <Route path="/ext/:extension/*" element={<ExtensionRoutes />} />
              <Route path="*" element={<NotFound />} />
            </Routes>
          </main>
        </div>
      </HashRouter>
    </ConsoleContext.Provider>
  );
}
