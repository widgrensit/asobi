import { useCallback, useEffect, useState } from 'react';
import { HashRouter, NavLink, Route, Routes } from 'react-router-dom';
import { config } from './config.js';
import { logout, whoami } from './api.js';
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

const NAV = [
  ['/', 'Overview'],
  ['/players', 'Players'],
  ['/matches', 'Matches'],
  ['/matchmaker', 'Matchmaker'],
  ['/leaderboards', 'Leaderboards'],
  ['/economy', 'Economy'],
  ['/chat', 'Chat'],
  ['/tournaments', 'Tournaments'],
  ['/notifications', 'Notifications'],
];

// Hash routing, not history routing. Deep links work, and the server needs no
// catch-all route to serve the shell under - which matters more than usual
// here, because a wildcard path segment is exactly the route form that has a
// traversal defect in Nova's own static handler.
export default function App() {
  const [actor, setActor] = useState(null);
  const [checked, setChecked] = useState(false);

  const signOut = useCallback(() => {
    setActor(null);
    logout().catch(() => {});
  }, []);

  useEffect(() => {
    whoami()
      .then((body) => setActor(body.data))
      .catch(() => setActor(null))
      .finally(() => setChecked(true));
  }, []);

  useEffect(() => {
    const onLost = () => setActor(null);
    window.addEventListener('asobi:unauthenticated', onLost);
    return () => window.removeEventListener('asobi:unauthenticated', onLost);
  }, []);

  if (!checked) return <div className="boot" aria-busy="true" />;
  if (!actor) return <Login onSignedIn={setActor} />;

  return (
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
          <ul className="nav-list">
            {NAV.map(([to, label]) => (
              <li key={to}>
                <NavLink to={to} end={to === '/'} className={({ isActive }) => (isActive ? 'nav-link on' : 'nav-link')}>
                  {label}
                </NavLink>
              </li>
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
            <Route path="*" element={<NotFound />} />
          </Routes>
        </main>
      </div>
    </HashRouter>
  );
}
