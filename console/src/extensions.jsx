import { Route, Routes, useParams } from 'react-router-dom';
import { useConsole } from './context.js';
import { Boundary } from './slot.jsx';
import { NotFound } from './screens.jsx';

// Everything an extension contributes hangs under `/ext/<name>`, so an
// extension route can never collide with a core one - present or future - and
// two extensions cannot collide with each other, because the segment is the
// extension name and two extensions cannot share a name. That is the same
// invariant that already keeps `ops/0` actions apart.
//
// An unknown extension answers the same 404 a mistyped core path does. It is
// reachable by typing a URL and by nothing else: the nav only offers what
// `resolveRegistry` kept.
export function ExtensionRoutes() {
  const { extension } = useParams();
  const { extensions } = useConsole();
  const found = extensions.find((candidate) => candidate.name === extension);
  if (!found) return <NotFound />;

  return (
    <Routes>
      {found.routes.map((route) => (
        <Route key={route.path} path={route.path} element={<Boundary name={found.name}>{route.element}</Boundary>} />
      ))}
      <Route path="*" element={<NotFound />} />
    </Routes>
  );
}
