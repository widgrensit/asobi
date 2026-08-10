// A slot component. It is rendered inside the core player screen and is handed
// the context that slot id promises - `{ player }` for `player.detail`.
//
// It also writes, which is the half `ops/0` exists for: opsExt with a method
// other than `get` posts a JSON body, and core wraps the call in an audit row
// naming the operator before the handler runs.
import { useState } from 'react';
import { ErrorBanner, Empty, ago, opsExt, text, useActor, useOps } from '@asobi/console';

export default function PlayerNotes({ player }) {
  const { data, error, loading, refresh } = useOps('/ext/notes/list', { player_id: player.id });
  const [body, setBody] = useState('');
  const [failed, setFailed] = useState(null);
  const actor = useActor();

  // `config` is not held by every session, and the ops plane would answer 403.
  // Asking here is so the form is not offered to somebody it will refuse.
  const mayWrite = actor.caps.includes('config');

  async function submit(event) {
    event.preventDefault();
    setFailed(null);
    try {
      await opsExt('notes', 'add', { method: 'post', body: { player_id: player.id, body } });
      setBody('');
      refresh();
    } catch (cause) {
      setFailed(cause);
    }
  }

  const notes = data?.data || [];

  return (
    <section className="card">
      <h2 className="card-title">Operator notes</h2>
      <ErrorBanner error={error || failed} onRetry={refresh} />
      {notes.length === 0 && !loading ? (
        <Empty>Nothing recorded about this player.</Empty>
      ) : (
        <dl className="detail">
          {notes.map((note) => (
            <div className="detail-row" key={note.id}>
              <dt>
                {text(note.author)} · {ago(note.written_at)}
              </dt>
              <dd>{text(note.body)}</dd>
            </div>
          ))}
        </dl>
      )}
      {mayWrite ? (
        // No `style` attribute anywhere: there is no style-src-attr in the
        // console's CSP, so the browser refuses an inline declaration. Classes
        // only, here as in core.
        <form className="toolbar" onSubmit={submit}>
          <input
            className="input"
            value={body}
            placeholder="Add a note"
            spellCheck="false"
            onChange={(event) => setBody(event.target.value)}
          />
          <button type="submit" className="btn btn-quiet" disabled={body === ''}>
            Add
          </button>
        </form>
      ) : null}
    </section>
  );
}
