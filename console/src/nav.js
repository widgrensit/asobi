// The navigation registry.
//
// Core's own entries used to be a literal array read straight by the shell.
// They are data here because an extension contributes to the same list, and
// two things producing one list have to agree on its shape.

// Sections render in this order, with a rule per section rather than a rule
// per item: core's own screens first, then whatever the installed extensions
// added, then the operator's own session. An extension cannot place itself
// above the screens an operator navigates by muscle memory.
export const SECTIONS = ['core', 'game', 'ops'];

// The sections an extension may put itself in. `core` is missing on purpose:
// it is the section the shell's own screens are in, and a manifest that named
// it with a low enough `order` sorted itself above Overview, which is the one
// thing the ordering above says it cannot do.
export const EXTENSION_SECTIONS = ['game', 'ops'];

export const CORE_NAV = [
  { path: '/', label: 'Overview', section: 'core', order: 0 },
  { path: '/players', label: 'Players', section: 'core', order: 10 },
  { path: '/matches', label: 'Matches', section: 'core', order: 20 },
  { path: '/matchmaker', label: 'Matchmaker', section: 'core', order: 30 },
  { path: '/leaderboards', label: 'Leaderboards', section: 'core', order: 40 },
  { path: '/economy', label: 'Economy', section: 'core', order: 50 },
  { path: '/chat', label: 'Chat', section: 'core', order: 60 },
  { path: '/tournaments', label: 'Tournaments', section: 'core', order: 70 },
  { path: '/notifications', label: 'Notifications', section: 'core', order: 80 },
];

// Ties break on label rather than on declaration order, because declaration
// order across several extensions is the link order of somebody's release and
// nothing an operator can reason about.
export function sortNav(items) {
  return [...items].sort((a, b) => {
    const section = SECTIONS.indexOf(a.section) - SECTIONS.indexOf(b.section);
    if (section !== 0) return section;
    if (a.order !== b.order) return a.order - b.order;
    return a.label.localeCompare(b.label);
  });
}
