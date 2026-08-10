import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import { config } from './config.js';
import { login } from './api.js';
import { useDebounced, useListParams, useOps } from './hooks.js';
import { ago, bytes, count, duration, shortId, text, timestamp } from './format.js';
import {
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
import { Slot } from './slot.jsx';

const ANY = { value: '', label: 'any' };

// One list screen, configured per endpoint. Every ops list takes the same
// parameters and returns the same envelope, so there is one thing to get
// right about paging, sorting, staleness and errors rather than nine.
function ListScreen({
  title,
  subtitle,
  path,
  columns,
  rowKey,
  rowLink,
  searchable = true,
  searchPlaceholder,
  filters = [],
  poll = 0,
  empty,
  extra,
}) {
  const params = useListParams();
  const [typed, setTyped] = useState(params.q);
  const q = useDebounced(typed, 250);

  useEffect(() => {
    if (q !== params.q) params.set({ q });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  const query = { limit: params.limit, offset: params.offset, sort: params.sort, order: params.order, q: params.q };
  for (const filter of filters) query[filter.name] = params.filters.get(filter.name) || '';

  const { data, error, loading, refresh } = useOps(path, query, { poll });

  function toggleSort(field) {
    const order = params.sort === field && params.order !== 'desc' ? 'desc' : 'asc';
    params.set({ sort: field, order });
  }

  return (
    <Screen
      title={title}
      subtitle={subtitle}
      actions={
        <button type="button" className="btn btn-quiet" onClick={refresh}>
          Refresh
        </button>
      }
    >
      <Toolbar right={<Pager page={data?.page} loading={loading} onOffset={(offset) => params.set({ offset })} />}>
        {searchable ? <Search value={typed} onChange={setTyped} placeholder={searchPlaceholder} /> : null}
        {filters.map((filter) => (
          <Select
            key={filter.name}
            label={filter.label}
            value={params.filters.get(filter.name) || ''}
            options={[ANY, ...filter.options]}
            onChange={(value) => params.set({ [filter.name]: value })}
          />
        ))}
      </Toolbar>
      <ErrorBanner error={error} onRetry={refresh} />
      {extra ? extra(data) : null}
      <DataTable
        columns={columns}
        rows={data?.data}
        rowKey={rowKey}
        rowLink={rowLink}
        sort={params.sort}
        order={params.order}
        onSort={toggleSort}
        loading={loading}
        empty={empty}
      />
      <Pager page={data?.page} loading={loading} onOffset={(offset) => params.set({ offset })} />
    </Screen>
  );
}

function DetailScreen({ title, path, back, backLabel, render }) {
  const { data, error, loading, refresh } = useOps(path, {});
  return (
    <Screen
      title={title}
      actions={
        <>
          <Link className="btn btn-quiet" to={back}>
            ← {backLabel}
          </Link>
          <button type="button" className="btn btn-quiet" onClick={refresh}>
            Refresh
          </button>
        </>
      }
    >
      <ErrorBanner error={error} onRetry={refresh} />
      {data ? render(data.data) : loading ? <div className="table-skeleton" aria-hidden="true" /> : null}
    </Screen>
  );
}

export function Login({ onSignedIn }) {
  const [secret, setSecret] = useState('');
  const [label, setLabel] = useState('');
  const [error, setError] = useState(null);
  const [busy, setBusy] = useState(false);

  async function submit(event) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const body = await login(secret, label || 'operator');
      setSecret('');
      onSignedIn(body.data);
    } catch (cause) {
      setError(cause);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="login">
      <form className="login-card" onSubmit={submit}>
        <h1 className="login-title">asobi ops</h1>
        <p className="login-sub">
          The operator secret is exchanged for a session cookie and is not kept by this page.
        </p>
        <label className="field">
          <span className="field-label">Operator secret</span>
          <input
            className="input"
            type="password"
            value={secret}
            autoFocus
            autoComplete="current-password"
            onChange={(event) => setSecret(event.target.value)}
          />
        </label>
        <label className="field">
          <span className="field-label">Your name (for the audit trail)</span>
          <input
            className="input"
            type="text"
            value={label}
            placeholder="operator"
            autoComplete="off"
            onChange={(event) => setLabel(event.target.value)}
          />
        </label>
        <ErrorBanner error={error} />
        <button className="btn btn-primary" type="submit" disabled={busy || secret === ''}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        <p className="login-foot">node {config.nodeVersion}</p>
      </form>
    </div>
  );
}

export function Overview() {
  const features = useOps('/features', {});
  const queue = useOps('/matchmaker', { limit: 5 }, { poll: 5000 });
  // Two seconds, matching what the old asobi_admin dashboard pushed. These are
  // VM reads with no database behind them, so the endpoint stays answerable
  // when Postgres is the thing that is unwell - which is when an operator is
  // most likely to be looking at this page.
  const runtime = useOps('/stats', {}, { poll: 2000 });
  const core = features.data?.data?.core;
  const extensions = features.data?.data?.extensions || [];
  const summary = queue.data?.queue;
  const vm = runtime.data?.data;

  return (
    <Screen title="Overview" subtitle="What this node is, and what it is doing right now.">
      <ErrorBanner error={features.error || queue.error} onRetry={features.refresh} />
      <div className="stats">
        <Stat
          label="Online players"
          value={vm && vm.online_players !== null ? count(vm.online_players) : '—'}
          hint={vm && vm.online_players === null ? 'presence unavailable' : null}
        />
        <Stat label="Node version" value={core ? core.version : '—'} hint={core ? core.name : null} />
        <Stat
          label="In queue"
          value={summary ? count(summary.waiting) : '—'}
          hint={summary ? `across ${summary.modes} mode(s)` : null}
        />
        <Stat
          label="Sample age"
          value={summary ? duration(summary.age_ms) : '—'}
          hint="counts are as old as the last matchmaker tick"
        />
        <Stat label="Extensions" value={count(extensions.length)} hint={extensions.length ? null : 'none installed'} />
      </div>

      {/* The node name is here rather than buried in a detail row because
          asobi clusters, and every node serves its own copy of this console.
          Behind a load balancer these numbers are whichever node answered -
          a reading you cannot act on unless you know which one that was. */}
      <section className="card">
        <h2 className="card-title">Runtime</h2>
        <p className="card-note">
          This node only. {vm ? <Mono>{vm.node}</Mono> : 'Waiting for the first sample.'}
        </p>
        <Detail
          fields={[
            ['Uptime', vm ? duration(vm.uptime_ms) : '—'],
            ['Processes', vm ? `${count(vm.process_count)} of ${count(vm.process_limit)}` : '—'],
            ['Run queue', vm ? count(vm.run_queue) : '—'],
            ['Schedulers', vm ? count(vm.scheduler_count) : '—'],
            ['Memory, total', vm ? bytes(vm.memory_total) : '—'],
            ['Memory, processes', vm ? bytes(vm.memory_processes) : '—'],
            ['Memory, ETS', vm ? bytes(vm.memory_ets) : '—'],
            ['Memory, binaries', vm ? bytes(vm.memory_binary) : '—'],
          ]}
        />
      </section>

      <section className="card">
        <h2 className="card-title">Core capabilities</h2>
        <p className="card-note">What is configured on this deployment, not what is compiled in.</p>
        <div className="chips">
          {(core?.capabilities || []).map((capability) => (
            <Pill key={capability.name} tone={capability.enabled ? 'good' : 'muted'}>
              {capability.name}
            </Pill>
          ))}
          {core && core.capabilities.length === 0 ? <Empty>Nothing reported.</Empty> : null}
        </div>
      </section>

      <Slot id="overview.stats" ctx={{ core, vm }} />

      <section className="card">
        <h2 className="card-title">Extensions</h2>
        {extensions.length === 0 ? (
          <Empty>No extensions installed. Screens for an extension appear here when it is.</Empty>
        ) : (
          <table className="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Version</th>
                <th>Provides</th>
              </tr>
            </thead>
            <tbody>
              {extensions.map((extension) => (
                <tr key={extension.name}>
                  <td>
                    <Mono>{extension.name}</Mono>
                  </td>
                  <td>{extension.version}</td>
                  <td>
                    <div className="chips">
                      {extension.capabilities
                        .filter((capability) => capability.enabled)
                        .map((capability) => (
                          <Pill key={capability.name}>{capability.name}</Pill>
                        ))}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </Screen>
  );
}

export function Players() {
  return (
    <ListScreen
      title="Players"
      subtitle="Search matches username and display name, case-insensitively."
      path="/players"
      searchPlaceholder="username or display name  ( / )"
      rowLink={(row) => `/players/${encodeURIComponent(row.id)}`}
      columns={[
        { key: 'username', label: 'Username', sort: 'username', render: (row) => text(row.username) },
        {
          key: 'display_name',
          label: 'Display name',
          sort: 'display_name',
          render: (row) => text(row.display_name),
        },
        { key: 'id', label: 'Id', sort: 'id', render: (row) => <Mono title={row.id}>{shortId(row.id)}</Mono> },
        {
          key: 'inserted_at',
          label: 'Registered',
          sort: 'inserted_at',
          render: (row) => <span title={timestamp(row.inserted_at)}>{ago(row.inserted_at)} ago</span>,
        },
        {
          key: 'updated_at',
          label: 'Updated',
          sort: 'updated_at',
          render: (row) => <span title={timestamp(row.updated_at)}>{ago(row.updated_at)} ago</span>,
        },
      ]}
    />
  );
}

export function PlayerDetail() {
  const { id } = useParams();
  return (
    <DetailScreen
      title="Player"
      path={`/players/${encodeURIComponent(id)}`}
      back="/players"
      backLabel="Players"
      render={(player) => (
        <>
          <section className="card">
            <Detail
              fields={[
                ['Id', <Mono key="id">{player.id}</Mono>],
                ['Username', text(player.username)],
                ['Display name', text(player.display_name)],
                ['Avatar', text(player.avatar_url)],
                ['Registered', timestamp(player.inserted_at)],
                ['Updated', timestamp(player.updated_at)],
              ]}
            />
          </section>
          <JsonBlock label="Metadata" value={player.metadata} />
          <Slot id="player.detail" ctx={{ player }} />
          <section className="card">
            <h2 className="card-title">Related</h2>
            <div className="chips">
              <Link className="btn btn-quiet" to={`/notifications?player_id=${encodeURIComponent(player.id)}`}>
                Notifications sent to this player
              </Link>
              <Link className="btn btn-quiet" to={`/chat?sender=${encodeURIComponent(player.id)}`}>
                Chat channels
              </Link>
              <Slot id="player.actions" ctx={{ player }} />
            </div>
          </section>
        </>
      )}
    />
  );
}

export function Matches() {
  return (
    <ListScreen
      title="Matches"
      subtitle="Match history. Search matches the mode name."
      path="/matches"
      searchPlaceholder="mode  ( / )"
      rowLink={(row) => `/matches/${encodeURIComponent(row.id)}`}
      filters={[
        {
          name: 'status',
          label: 'status',
          options: [
            { value: 'pending', label: 'pending' },
            { value: 'active', label: 'active' },
            { value: 'finished', label: 'finished' },
          ],
        },
      ]}
      columns={[
        { key: 'id', label: 'Id', sort: 'id', render: (row) => <Mono title={row.id}>{shortId(row.id)}</Mono> },
        { key: 'mode', label: 'Mode', sort: 'mode', render: (row) => text(row.mode) },
        {
          key: 'status',
          label: 'Status',
          sort: 'status',
          render: (row) => <Pill tone={row.status === 'active' ? 'good' : 'neutral'}>{text(row.status)}</Pill>,
        },
        {
          key: 'started_at',
          label: 'Started',
          sort: 'started_at',
          render: (row) => <span title={timestamp(row.started_at)}>{timestamp(row.started_at)}</span>,
        },
        {
          key: 'finished_at',
          label: 'Finished',
          sort: 'finished_at',
          render: (row) => <span title={timestamp(row.finished_at)}>{timestamp(row.finished_at)}</span>,
        },
      ]}
    />
  );
}

export function MatchDetail() {
  const { id } = useParams();
  return (
    <DetailScreen
      title="Match"
      path={`/matches/${encodeURIComponent(id)}`}
      back="/matches"
      backLabel="Matches"
      render={(match) => (
        <>
          <section className="card">
            <Detail
              fields={[
                ['Id', <Mono key="id">{match.id}</Mono>],
                ['Mode', text(match.mode)],
                ['Status', <Pill key="s">{text(match.status)}</Pill>],
                ['Started', timestamp(match.started_at)],
                ['Finished', timestamp(match.finished_at)],
                ['Recorded', timestamp(match.inserted_at)],
              ]}
            />
          </section>
          <JsonBlock label="Result" value={match.result} />
          <Slot id="match.detail" ctx={{ match }} />
        </>
      )}
    />
  );
}

export function Matchmaker() {
  return (
    <ListScreen
      title="Matchmaker"
      subtitle="One row per mode, deepest queue first. Refreshes every 3 seconds."
      path="/matchmaker"
      searchable={false}
      poll={3000}
      rowKey={(row) => row.mode}
      empty="Nothing is queued."
      extra={(data) =>
        data?.queue ? (
          <div className="stats">
            <Stat label="Waiting" value={count(data.queue.waiting)} />
            <Stat label="Modes" value={count(data.queue.modes)} />
            <Stat
              label="Sample age"
              value={duration(data.queue.age_ms)}
              hint={`sampled ${timestamp(data.queue.sampled_at)}`}
            />
          </div>
        ) : null
      }
      columns={[
        { key: 'mode', label: 'Mode', sort: 'mode', render: (row) => text(row.mode) },
        { key: 'waiting', label: 'Waiting', sort: 'waiting', numeric: true, render: (row) => count(row.waiting) },
        {
          key: 'oldest_wait_ms',
          label: 'Oldest wait',
          sort: 'oldest_wait_ms',
          numeric: true,
          render: (row) => duration(row.oldest_wait_ms),
        },
        {
          key: 'average_wait_ms',
          label: 'Average wait',
          sort: 'average_wait_ms',
          numeric: true,
          render: (row) => duration(row.average_wait_ms),
        },
      ]}
    />
  );
}

export function Leaderboards() {
  return (
    <ListScreen
      title="Leaderboards"
      subtitle="Boards rather than scores. `live` is whether a process is behind it right now."
      path="/leaderboards"
      searchPlaceholder="board id  ( / )"
      rowKey={(row) => row.board_id}
      rowLink={(row) => `/leaderboards/${encodeURIComponent(row.board_id)}`}
      columns={[
        { key: 'board_id', label: 'Board', sort: 'board_id', render: (row) => <Mono>{row.board_id}</Mono> },
        { key: 'entries', label: 'Entries', sort: 'entries', numeric: true, render: (row) => count(row.entries) },
        {
          key: 'top_score',
          label: 'Top score',
          sort: 'top_score',
          numeric: true,
          render: (row) => count(row.top_score),
        },
        { key: 'live', label: 'Live', render: (row) => <Bool value={row.live} /> },
        {
          key: 'updated_at',
          label: 'Updated',
          sort: 'updated_at',
          render: (row) => <span title={timestamp(row.updated_at)}>{ago(row.updated_at)} ago</span>,
        },
      ]}
    />
  );
}

export function LeaderboardEntries() {
  const { id } = useParams();
  return (
    <ListScreen
      title={`Board · ${id}`}
      subtitle="Persisted scores. A score submitted seconds ago reaches the public top-N before it reaches here."
      path={`/leaderboards/${encodeURIComponent(id)}/entries`}
      searchable={false}
      rowKey={(row) => row.id}
      columns={[
        { key: 'rank', label: 'Rank', numeric: true, render: (row) => count(row.rank) },
        {
          key: 'player_id',
          label: 'Player',
          sort: 'player_id',
          render: (row) => (
            <Link className="row-link" to={`/players/${encodeURIComponent(row.player_id)}`}>
              <Mono title={row.player_id}>{shortId(row.player_id)}</Mono>
            </Link>
          ),
        },
        { key: 'score', label: 'Score', sort: 'score', numeric: true, render: (row) => count(row.score) },
        {
          key: 'sub_score',
          label: 'Sub-score',
          sort: 'sub_score',
          numeric: true,
          render: (row) => count(row.sub_score),
        },
        {
          key: 'updated_at',
          label: 'Updated',
          sort: 'updated_at',
          render: (row) => <span title={timestamp(row.updated_at)}>{ago(row.updated_at)} ago</span>,
        },
      ]}
    />
  );
}

// Two tables on one page, which is why the console renders a screen as a list
// of sections rather than one view per endpoint: an operator pricing an item
// wants the catalogue and the store side by side.
export function Economy() {
  return (
    <div className="stack">
      <ListScreen
        title="Item catalogue"
        subtitle="Definitions. Search matches slug and name."
        path="/economy/items"
        searchPlaceholder="slug or name  ( / )"
        rowLink={(row) => `/economy/items/${encodeURIComponent(row.id)}`}
        columns={[
          { key: 'slug', label: 'Slug', sort: 'slug', render: (row) => <Mono>{text(row.slug)}</Mono> },
          { key: 'name', label: 'Name', sort: 'name', render: (row) => text(row.name) },
          { key: 'category', label: 'Category', sort: 'category', render: (row) => text(row.category) },
          { key: 'rarity', label: 'Rarity', sort: 'rarity', render: (row) => text(row.rarity) },
          { key: 'stackable', label: 'Stackable', render: (row) => <Bool value={row.stackable} /> },
          {
            key: 'inserted_at',
            label: 'Added',
            sort: 'inserted_at',
            render: (row) => <span title={timestamp(row.inserted_at)}>{ago(row.inserted_at)} ago</span>,
          },
        ]}
      />
      <ListScreen
        title="Store listings"
        subtitle="No search here: a listing holds no prose. Find the item above and filter by its id."
        path="/economy/listings"
        searchable={false}
        filters={[
          {
            name: 'active',
            label: 'active',
            options: [
              { value: 'true', label: 'true' },
              { value: 'false', label: 'false' },
            ],
          },
        ]}
        columns={[
          {
            key: 'item_def_id',
            label: 'Item',
            sort: 'item_def_id',
            render: (row) => (
              <Link className="row-link" to={`/economy/items/${encodeURIComponent(row.item_def_id)}`}>
                <Mono title={row.item_def_id}>{shortId(row.item_def_id)}</Mono>
              </Link>
            ),
          },
          { key: 'currency', label: 'Currency', sort: 'currency', render: (row) => text(row.currency) },
          { key: 'price', label: 'Price', sort: 'price', numeric: true, render: (row) => count(row.price) },
          { key: 'active', label: 'Active', sort: 'active', render: (row) => <Bool value={row.active} /> },
          { key: 'valid_from', label: 'From', sort: 'valid_from', render: (row) => timestamp(row.valid_from) },
          { key: 'valid_until', label: 'Until', sort: 'valid_until', render: (row) => timestamp(row.valid_until) },
        ]}
      />
    </div>
  );
}

export function EconomyItem() {
  const { id } = useParams();
  return (
    <DetailScreen
      title="Item definition"
      path={`/economy/items/${encodeURIComponent(id)}`}
      back="/economy"
      backLabel="Economy"
      render={(item) => (
        <>
          <section className="card">
            <Detail
              fields={[
                ['Id', <Mono key="id">{item.id}</Mono>],
                ['Slug', <Mono key="slug">{text(item.slug)}</Mono>],
                ['Name', text(item.name)],
                ['Category', text(item.category)],
                ['Rarity', text(item.rarity)],
                ['Stackable', <Bool key="s" value={item.stackable} />],
                ['Added', timestamp(item.inserted_at)],
              ]}
            />
          </section>
          <JsonBlock label="Metadata" value={item.metadata} />
        </>
      )}
    />
  );
}

export function Chat() {
  return (
    <ListScreen
      title="Chat channels"
      subtitle="Live channels on this node. Process state, so it changes between reads."
      path="/chat/channels"
      searchPlaceholder="channel id  ( / )"
      rowKey={(row) => row.channel_id}
      rowLink={(row) => `/chat/${encodeURIComponent(row.channel_id)}`}
      empty="No channels are running on this node. History is still readable by channel id."
      columns={[
        { key: 'channel_id', label: 'Channel', sort: 'channel_id', render: (row) => <Mono>{row.channel_id}</Mono> },
        { key: 'members', label: 'Members', sort: 'members', numeric: true, render: (row) => count(row.members) },
      ]}
    />
  );
}

export function ChatMessages() {
  const { id } = useParams();
  return (
    <ListScreen
      title={`Channel · ${id}`}
      subtitle="Persisted history. Search matches message content - the read a report needs."
      path={`/chat/channels/${encodeURIComponent(id)}/messages`}
      searchPlaceholder="message content  ( / )"
      columns={[
        {
          key: 'sent_at',
          label: 'Sent',
          sort: 'sent_at',
          render: (row) => <span title={timestamp(row.sent_at)}>{timestamp(row.sent_at)}</span>,
        },
        {
          key: 'sender_id',
          label: 'Sender',
          sort: 'sender_id',
          render: (row) => (
            <Link className="row-link" to={`/players/${encodeURIComponent(row.sender_id)}`}>
              <Mono title={row.sender_id}>{shortId(row.sender_id)}</Mono>
            </Link>
          ),
        },
        { key: 'channel_type', label: 'Type', sort: 'channel_type', render: (row) => text(row.channel_type) },
        { key: 'content', label: 'Content', render: (row) => <span className="wrap">{text(row.content)}</span> },
      ]}
    />
  );
}

export function Tournaments() {
  return (
    <ListScreen
      title="Tournaments"
      subtitle="`live` is whether a process is actually running. A row can be active with no process after a restart."
      path="/tournaments"
      searchPlaceholder="name  ( / )"
      rowLink={(row) => `/tournaments/${encodeURIComponent(row.id)}`}
      filters={[
        {
          name: 'status',
          label: 'status',
          options: [
            { value: 'scheduled', label: 'scheduled' },
            { value: 'active', label: 'active' },
            { value: 'finished', label: 'finished' },
          ],
        },
      ]}
      columns={[
        { key: 'name', label: 'Name', sort: 'name', render: (row) => text(row.name) },
        {
          key: 'status',
          label: 'Status',
          sort: 'status',
          render: (row) => <Pill tone={row.status === 'active' ? 'good' : 'neutral'}>{text(row.status)}</Pill>,
        },
        {
          key: 'live',
          label: 'Live',
          render: (row) => (
            <Bool value={row.live} no={row.status === 'active' ? 'no — stale' : 'no'} />
          ),
        },
        {
          key: 'leaderboard_id',
          label: 'Board',
          sort: 'leaderboard_id',
          render: (row) => <Mono>{text(row.leaderboard_id)}</Mono>,
        },
        { key: 'start_at', label: 'Starts', sort: 'start_at', render: (row) => timestamp(row.start_at) },
        { key: 'end_at', label: 'Ends', sort: 'end_at', render: (row) => timestamp(row.end_at) },
      ]}
    />
  );
}

export function TournamentDetail() {
  const { id } = useParams();
  return (
    <DetailScreen
      title="Tournament"
      path={`/tournaments/${encodeURIComponent(id)}`}
      back="/tournaments"
      backLabel="Tournaments"
      render={(tournament) => (
        <>
          <section className="card">
            <Detail
              fields={[
                ['Id', <Mono key="id">{tournament.id}</Mono>],
                ['Name', text(tournament.name)],
                ['Status', <Pill key="s">{text(tournament.status)}</Pill>],
                ['Live', <Bool key="l" value={tournament.live} />],
                [
                  'Board',
                  <Link key="b" className="row-link" to={`/leaderboards/${encodeURIComponent(tournament.leaderboard_id)}`}>
                    <Mono>{text(tournament.leaderboard_id)}</Mono>
                  </Link>,
                ],
                ['Max entries', count(tournament.max_entries)],
                ['Starts', timestamp(tournament.start_at)],
                ['Ends', timestamp(tournament.end_at)],
              ]}
            />
          </section>
          <JsonBlock label="Entry fee" value={tournament.entry_fee} />
          <JsonBlock label="Rewards" value={tournament.rewards} />
        </>
      )}
    />
  );
}

export function Notifications() {
  return (
    <ListScreen
      title="Notifications"
      subtitle="Send history. Answers the question a broadcast raises: who got it, and who opened it."
      path="/notifications"
      searchPlaceholder="subject  ( / )"
      filters={[
        {
          name: 'read',
          label: 'read',
          options: [
            { value: 'true', label: 'true' },
            { value: 'false', label: 'false' },
          ],
        },
      ]}
      columns={[
        {
          key: 'sent_at',
          label: 'Sent',
          sort: 'sent_at',
          render: (row) => <span title={timestamp(row.sent_at)}>{timestamp(row.sent_at)}</span>,
        },
        {
          key: 'player_id',
          label: 'Player',
          sort: 'player_id',
          render: (row) => (
            <Link className="row-link" to={`/players/${encodeURIComponent(row.player_id)}`}>
              <Mono title={row.player_id}>{shortId(row.player_id)}</Mono>
            </Link>
          ),
        },
        { key: 'type', label: 'Type', sort: 'type', render: (row) => text(row.type) },
        { key: 'subject', label: 'Subject', sort: 'subject', render: (row) => text(row.subject) },
        { key: 'read', label: 'Read', sort: 'read', render: (row) => <Bool value={row.read} /> },
      ]}
    />
  );
}

export function NotFound() {
  const navigate = useNavigate();
  return (
    <Screen title="No such screen">
      <Empty>
        That path is not part of the console.{' '}
        <button type="button" className="btn btn-quiet" onClick={() => navigate('/')}>
          Back to the overview
        </button>
      </Empty>
    </Screen>
  );
}
