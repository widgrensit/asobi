// The console manifest. Default export, one object, no registration anywhere.
//
// `rebar3 asobi console` finds this file by its path and compiles it into the
// host's console bundle. `name` is info().name from the extension manifest -
// the application is asobi_notes, the extension is notes - and it is what
// /ext/<name> and the installed check are keyed by.
import Notes from './notes.jsx';
import PlayerNotes from './player-notes.jsx';

export default {
  name: 'notes',
  apiVersion: 1,

  // Relative to /ext/notes. `section` defaults to 'game', which sits below
  // every core screen whatever order an extension asks for.
  nav: [{ path: '', label: 'Notes', section: 'game', order: 10 }],

  routes: [{ path: '', element: <Notes /> }],

  // The part that is not a new page. An operator reading a player does not
  // want the notes about that player behind another click.
  slots: {
    'player.detail': PlayerNotes,
  },
};
