# Voting

Asobi includes an in-match voting system for roguelike-style group decisions
such as path selection, item picks, event choices, and run modifiers.

## How It Works

1. Game mode (or match server) starts a vote with options and a timed window
2. Eligible players receive a `match.vote_start` event via WebSocket
3. Players cast votes during the window
4. When the window expires, votes are tallied and the result is broadcast
5. The game mode receives the result via the `vote_resolved/3` callback

## Starting a Vote

There are two ways to start a vote:

### Automatic (via `vote_requested` callback)

The match server polls the `vote_requested/1` callback after every tick. Return
a vote config to start a vote, or `none`/`nil` to skip. This is the simplest
approach and works for both Erlang and Lua game modules. Votes can be triggered
at any point during gameplay - not just between rounds.

```erlang
vote_requested(#{phase := vote_pending} = _GameState) ->
    {ok, #{
        template => ~"path_choice",
        options => [
            #{id => ~"jungle", label => ~"Jungle Path"},
            #{id => ~"volcano", label => ~"Volcano Path"}
        ],
        window_ms => 15000,
        method => ~"plurality"
    }};
vote_requested(_) ->
    none.
```

When a vote starts this way, the optional `vote_started/1` callback is called
to let the game module update its state (e.g. change phase).

### Manual (via match server API)

Votes can also be started explicitly from a game mode callback:

```erlang
%% From inside a game module callback
asobi_match_server:start_vote(MatchPid, #{
    template => ~"path_choice",
    options => [
        #{id => ~"jungle", label => ~"Jungle Path"},
        #{id => ~"volcano", label => ~"Volcano Path"},
        #{id => ~"caves", label => ~"Ice Caves"}
    ],
    window_ms => 15000,
    method => ~"plurality",
    visibility => ~"live"
}).
```

### Config Options

| Key            | Type           | Default        | Description                        |
|----------------|----------------|----------------|------------------------------------|
| `options`      | `[map()]`      | required       | List of `#{id, label}` option maps |
| `template`     | `binary()`     | `"default"`    | Template name (resolved from config) |
| `window_ms`    | `pos_integer()`| `15000`        | Vote window in milliseconds        |
| `method`       | `binary()`     | `"plurality"`  | `"plurality"`, `"approval"`, or `"weighted"` |
| `visibility`   | `binary()`     | `"live"`       | `"live"` or `"hidden"`             |
| `tie_breaker`  | `binary()`     | `"random"`     | `"random"` or `"first"`            |
| `veto_enabled` | `boolean()`    | `false`        | Allow players to veto              |
| `weights`      | `map()`        | `#{}`          | Voter weights for `"weighted"` method |
| `max_revotes`  | `pos_integer()`| `3`            | Max times a voter can change their vote |

The match server automatically fills in `match_id`, `match_pid`, and
`eligible` (all current players) when starting the vote.

## Voting Methods

### Plurality

Each player picks exactly one option. The option with the most votes wins.
Ties are broken by the configured `tie_breaker` strategy.

### Approval

Each player submits a list of all options they approve of. The option with
the highest total approval count wins. Good for "avoid the worst option"
scenarios.

### Weighted

Each vote is multiplied by the voter's weight. Pass weights via config:

```erlang
asobi_match_server:start_vote(MatchPid, #{
    options => Options,
    method => ~"weighted",
    weights => #{~"player1" => 3, ~"player2" => 1}
}).
```

Players not in the weights map default to weight 1. Useful for
performance-based voting or role-based voting.

### Ranked Choice

Each player submits a ranked list. The option with fewest first-choice votes
is eliminated each round, and those votes transfer to the next preference.
Continues until one option has a majority.

```erlang
asobi_match_server:start_vote(MatchPid, #{
    options => Options,
    method => ~"ranked"
}).
```

Clients send a list for `option_id`:

```json
{"type": "vote.cast", "payload": {"vote_id": "...", "option_id": ["jungle", "caves", "volcano"]}}
```

Live tallies show first-choice counts. The final result includes the winner
after all elimination rounds.

## Spectator Voting

Spectators are a separate voter pool whose votes are merged with player
votes using a configurable weight ratio.

```erlang
asobi_match_server:start_vote(MatchPid, #{
    options => Options,
    spectators => [~"spec1", ~"spec2", ~"spec3"],
    spectator_weight => 0.3  %% spectators get 30% influence, players 70%
}).
```

Both pools are tallied independently, normalized, then merged:
`score = player_normalized * (1 - spectator_weight) + spectator_normalized * spectator_weight`

For spectator-only votes (audience decides), set `eligible => []` and
`spectator_weight => 1.0`.

## Async Voting

For non-real-time games where not all players are online simultaneously.

### Quorum

Require a minimum fraction of eligible voters before the result is valid:

```erlang
#{quorum => 0.5}  %% at least 50% must vote
```

If quorum is not met when the window expires, the result has
`winner => undefined` and `status => "no_quorum"`.

### Default Votes

Set fallback votes for players who don't participate:

```erlang
#{default_votes => #{~"player2" => ~"opt_b", ~"player3" => ~"opt_a"}}
```

Defaults are applied at resolution time only — they don't count as active
votes during the window. Players who vote explicitly override their default.

### Delegation

Let a player's vote follow another player's choice:

```erlang
#{delegation => #{~"player3" => ~"player1"}}
```

If player3 doesn't vote but player1 voted for `opt_a`, player3's vote
becomes `opt_a` at resolution time. If the delegate also didn't vote,
no vote is added.

## Vote Templates

Define reusable vote configurations in your app config. Per-call config
overrides template defaults:

```erlang
{asobi, [
    {vote_templates, #{
        ~"boon_pick" => #{method => ~"plurality", window_ms => 15000, visibility => ~"live"},
        ~"path_choice" => #{method => ~"approval", window_ms => 20000, visibility => ~"hidden"},
        ~"weighted_pick" => #{method => ~"weighted", window_ms => 15000}
    }}
]}
```

Then start a vote with just the template name and options:

```erlang
asobi_match_server:start_vote(MatchPid, #{
    template => ~"boon_pick",
    options => Options
}).
```

## Window Types

The `window_type` config controls when a vote closes. All types have a
maximum `window_ms` timeout as a safety net.

### Fixed (default)

Vote runs for exactly `window_ms`, then closes. Simple and predictable.

```erlang
#{window_type => ~"fixed", window_ms => 15000}
```

### Ready-up

Closes as soon as all eligible voters have cast a vote, or when `window_ms`
expires. Best for small groups where everyone is engaged.

```erlang
#{window_type => ~"ready_up", window_ms => 30000}
```

### Hybrid

Like ready-up, but enforces a minimum `min_window_ms` before early close.
Prevents snap decisions while still closing early once everyone votes.

```erlang
#{window_type => ~"hybrid", window_ms => 30000, min_window_ms => 5000}
```

### Adaptive

Starts with full `window_ms`, but when a supermajority threshold is reached,
the remaining time shrinks to 3 seconds. Gives latecomers a last chance
without forcing everyone to wait.

```erlang
#{window_type => ~"adaptive", window_ms => 20000, supermajority => 0.75}
```

If the supermajority is lost (e.g. someone changes their vote), the timer
resets to the original remaining time.

## Rate Limiting

Voters can change their vote during the window, but are limited to
`max_revotes` changes (default 3). After that, `{error, rate_limited}` is
returned. The initial vote does not count against the limit.

## Game Mode Integration

Implement the optional `asobi_match` callbacks to react to vote results:

```erlang
-module(my_roguelike).
-behaviour(asobi_match).

%% ... init/1, join/2, leave/2, handle_input/3, get_state/2 ...

vote_resolved(~"path_choice", #{winner := WinnerId}, GameState) ->
    %% Apply the voted path to game state
    {ok, GameState#{current_path => WinnerId}};
vote_resolved(~"item_pick", #{winner := ItemId}, GameState) ->
    {ok, add_item(ItemId, GameState)}.
```

Both callbacks are optional. If `vote_resolved/3` is not implemented, the
vote still runs and broadcasts results to clients — the game mode just
doesn't react server-side.

## WebSocket Protocol

### Casting a Vote (client to server)

```json
{
  "type": "vote.cast",
  "cid": "v1",
  "payload": {
    "vote_id": "...",
    "option_id": "jungle"
  }
}
```

For approval voting, `option_id` is a list:

```json
{"option_id": ["jungle", "caves"]}
```

Response:

```json
{"type": "vote.cast_ok", "cid": "v1", "payload": {"success": true}}
```

Players can change their vote by sending another `vote.cast` during the
window. The new vote replaces the previous one.

### Server Push Events

All vote events are broadcast to match players as `match.*` events:

#### `match.vote_start`

A new vote has started.

```json
{
  "type": "match.vote_start",
  "payload": {
    "vote_id": "...",
    "options": [
      {"id": "jungle", "label": "Jungle Path"},
      {"id": "volcano", "label": "Volcano Path"},
      {"id": "caves", "label": "Ice Caves"}
    ],
    "window_ms": 15000,
    "method": "plurality"
  }
}
```

#### `match.vote_tally`

Running tally update (only with `"live"` visibility). Sent each time a vote
is cast.

```json
{
  "type": "match.vote_tally",
  "payload": {
    "vote_id": "...",
    "tallies": {"jungle": 2, "volcano": 1, "caves": 0},
    "time_remaining_ms": 8432,
    "total_votes": 3
  }
}
```

#### `match.vote_result`

Vote has closed and the winner is determined.

```json
{
  "type": "match.vote_result",
  "payload": {
    "vote_id": "...",
    "winner": "jungle",
    "counts": {"jungle": 2, "volcano": 1, "caves": 0},
    "distribution": {"jungle": 0.666, "volcano": 0.333, "caves": 0.0},
    "total_votes": 3,
    "turnout": 1.0
  }
}
```

#### `match.vote_vetoed`

A player has vetoed the vote (when `veto_enabled` is true).

```json
{
  "type": "match.vote_vetoed",
  "payload": {
    "vote_id": "...",
    "vetoed_by": "player_id"
  }
}
```

## REST API

### List votes for a match

```bash
curl http://localhost:8082/api/v1/matches/<match_id>/votes \
  -H 'Authorization: Bearer <token>'
```

Returns the most recent 50 votes for the match, ordered by newest first.

### Get a single vote

```bash
curl http://localhost:8082/api/v1/votes/<vote_id> \
  -H 'Authorization: Bearer <token>'
```

## Visibility Modes

- **`"live"`**: Running tallies are broadcast after each vote and included in
  state queries. Creates excitement and enables strategic voting.
- **`"hidden"`**: Tallies are not shown until the vote closes. Prevents
  bandwagon effects. Only total vote count is visible during the window.

## Veto

When `veto_enabled` is true, any eligible voter can veto the vote. This
immediately cancels it and notifies all players. Use sparingly — typically
as a limited-use resource managed by the game mode.

## Majority Tyranny Mitigations

When the same majority always outvotes a minority, voting becomes
frustrating. Asobi provides three configurable mitigations.

### Frustration Accumulator

Players who vote for the losing option accumulate frustration. On the
next vote, their weight is boosted: `1 + frustration_count * frustration_bonus`.
When they finally win, their frustration resets to 0.

Configure at match level:

```erlang
asobi_match_sup:start_match(#{
    game_module => MyGame,
    frustration_bonus => 0.5  %% default 0.5, set 0 to disable
}).
```

A player who lost 3 consecutive votes gets weight `1 + 3 * 0.5 = 2.5`,
making their vote count 2.5x. This only applies to weighted voting or
when frustration weights are merged (which happens automatically when
starting votes via the match server).

### Supermajority Requirement

Force high-stakes votes to require a supermajority. If no option reaches
the threshold, the result has `winner => undefined` and
`status => "no_consensus"`.

```erlang
asobi_match_server:start_vote(MatchPid, #{
    options => Options,
    require_supermajority => true,
    supermajority => 0.75  %% 75% required
}).
```

The game mode's `vote_resolved/3` callback receives the no-consensus
result and can decide what to do (random pick, re-vote, default option).

### Veto Tokens

Give players a limited number of vetoes per match. When used, the current
vote is immediately cancelled. The game mode decides what happens next.

Configure at match level:

```erlang
asobi_match_sup:start_match(#{
    game_module => MyGame,
    veto_tokens_per_player => 2  %% default 0 (disabled)
}).
```

Clients use veto tokens via WebSocket:

```json
{"type": "vote.veto", "payload": {"vote_id": "..."}}
```

The match server checks token availability before forwarding to the vote
server. Returns `{error, no_veto_tokens}` when exhausted.

## Grace Period

Votes arriving within 500ms after the window closes are still accepted to
compensate for network latency.
