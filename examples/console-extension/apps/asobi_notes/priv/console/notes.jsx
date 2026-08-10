// A list screen, built from the same primitives core's own list screens use.
// `useOps` is what keeps the previous rows on screen while the next page
// loads, and `useListParams` is what puts the filter and the page in the URL so
// a link to what you are looking at carries them.
import {
  DataTable,
  ErrorBanner,
  Link,
  Mono,
  Pager,
  Screen,
  Toolbar,
  ago,
  text,
  useListParams,
  useOps,
} from '@asobi/console';

export default function Notes() {
  const params = useListParams();
  const { data, error, loading, refresh } = useOps('/ext/notes/list', {
    limit: params.limit,
    offset: params.offset,
  });

  return (
    <Screen
      title="Notes"
      subtitle="What operators have recorded about players on this node."
      actions={
        <button type="button" className="btn btn-quiet" onClick={refresh}>
          Refresh
        </button>
      }
    >
      <Toolbar right={<Pager page={data?.page} loading={loading} onOffset={(offset) => params.set({ offset })} />} />
      <ErrorBanner error={error} onRetry={refresh} />
      <DataTable
        columns={[
          {
            key: 'player_id',
            label: 'Player',
            render: (note) => (
              // Absolute, because a link out of an extension screen into a core
              // one is not relative to /ext/notes.
              <Link to={`/players/${encodeURIComponent(note.player_id)}`}>
                <Mono>{note.player_id}</Mono>
              </Link>
            ),
          },
          { key: 'body', label: 'Note', render: (note) => text(note.body) },
          { key: 'author', label: 'By', render: (note) => text(note.author) },
          { key: 'written_at', label: 'Written', render: (note) => ago(note.written_at) },
        ]}
        rows={data?.data}
        rowKey={(note) => note.id}
        loading={loading}
        empty="No notes yet."
      />
      <Pager page={data?.page} loading={loading} onOffset={(offset) => params.set({ offset })} />
    </Screen>
  );
}
