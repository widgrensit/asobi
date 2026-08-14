# Voting

An in-session voting system for group decisions: path selection, item picks,
event choices, run modifiers. It runs inside a match or a world.

## The namespace follows the session

Worlds run votes exactly as matches do, and the frames a client receives are
named after the session it is in:

| Session | Push frames |
|---|---|
| Match | `match.vote_start`, `match.vote_tally`, `match.vote_result`, `match.vote_vetoed` |
| World | `world.vote_start`, `world.vote_tally`, `world.vote_result`, `world.vote_vetoed` |

A world client listening for `match.vote_start` receives nothing at all. Listen
for the namespace your game runs in.

## How it works

1. The game asks for a vote, with options and a timed window.
2. Eligible players receive `vote_start` in their session's namespace.
3. Players cast votes during the window with the `vote.cast` frame.
4. The window closes, votes are tallied and the result is broadcast.
5. The game module's optional `vote_resolved` callback receives the result.

## Starting a vote from Lua

There are two Lua triggers, one per session type. Both are polled by the server
after every tick.

**A match script** implements `vote_requested(state)`. Return a config table to
start a vote, or `nil` to skip:

```lua
function vote_requested(state)
  if state.boss_defeated and not state.boon_picked then
    return {
      template  = "boon_pick",
      options   = { { id = "shield", label = "Shield" },
                    { id = "speed",  label = "Speed" } },
      method    = "plurality",
      window_ms = 15000
    }
  end
  return nil
end
```

Returning `nil`, `false` or an empty table skips.

An Erlang match module may also implement `vote_started/1`, which fires when a
vote starts this way. The Lua bridge does not export it, so a Lua
`vote_started` function is never called. Set your own flag inside
`vote_requested` instead.

**A world script** sets `state._vote` inside `post_tick`, because a world has no
`vote_requested` callback:

```lua
function post_tick(tick, state)
  if state.boss_hp <= 0 then
    state._vote = {
      template  = "boon_pick",
      options   = { { id = "shield", label = "Shield" },
                    { id = "speed",  label = "Speed" } },
      method    = "plurality",
      window_ms = 15000
    }
    state.boss_hp = 10000    -- clear the trigger so it does not re-fire
  end
  return state
end
```

Clear whatever condition set `_vote`, or the next tick sets it again.

Before asobi v0.87.0 neither trigger worked. The decoded table reached the vote
server with string keys where it reads atom ones, so the vote failed to start
and the failure was swallowed at both call sites - no `vote_start` frame, no log
line naming the script. If you are on an older server, a vote has to be started
from Erlang.

## Starting a vote from Erlang

A game module written in Erlang calls `asobi_match_server:start_vote/2` or
`asobi_world_server:start_vote/2` directly, with the session pid and a config
map. A Lua script does not need this - return the config from `vote_requested`
instead, as above.

```erlang
asobi_match_server:start_vote(MatchPid, #{
    template   => ~"path_choice",
    options    => [
        #{id => ~"jungle",  label => ~"Jungle Path"},
        #{id => ~"volcano", label => ~"Volcano Path"},
        #{id => ~"caves",   label => ~"Ice Caves"}
    ],
    window_ms  => 15000,
    method     => ~"plurality",
    visibility => ~"live"
}).
```

An Erlang game module can also implement `vote_requested/1`, returning
`{ok, Config}` or `none`, which the match server polls after every tick.

The server fills in `match_id`, `match_pid`, `eligible` (every current player)
and merged `weights` before the vote starts, so a caller never supplies them.

Starting a vote in a match that has not started yet answers
`{error, match_not_started}`, and in a paused match `{error, match_paused}`.

## Config reference

| Key | Type | Default | Description |
|---|---|---|---|
| `options` | `[map()]` | required | List of `#{id, label}` option maps |
| `template` | `binary()` | `"default"` | Template name, resolved from `vote_templates` |
| `vote_id` | `binary()` | generated | Override the vote id |
| `window_ms` | `pos_integer()` | `15000` | Vote window in milliseconds |
| `method` | `binary()` | `"plurality"` | `"plurality"`, `"approval"`, `"weighted"` or `"ranked"` |
| `visibility` | `binary()` | `"live"` | `"live"` or `"hidden"` |
| `tie_breaker` | `binary()` | `"random"` | `"random"` or `"first"` |
| `veto_enabled` | `boolean()` | `false` | Allow an eligible voter to veto |
| `weights` | `map()` | `#{}` | `#{voter_id => number()}` for `"weighted"` |
| `max_revotes` | `pos_integer()` | `3` | Times a voter may change their vote |
| `window_type` | `binary()` | `"fixed"` | `"fixed"`, `"ready_up"`, `"hybrid"` or `"adaptive"` |
| `min_window_ms` | `pos_integer()` | `5000` | Minimum window before `"hybrid"` may close early |
| `supermajority` | `float()` | `0.75` | Threshold for `"adaptive"` early close and for `require_supermajority` |
| `require_supermajority` | `boolean()` | `false` | Winner must reach `supermajority` or the result is no-consensus |
| `spectators` | `[binary()]` | `[]` | Spectator voter ids, a separate pool |
| `spectator_weight` | `float()` | `0.3` | Spectator share of the merged score, 0.0-1.0 |
| `quorum` | `float()` | `0.0` | Minimum fraction of eligible voters for a valid result. 0.0 disables |
| `default_votes` | `map()` | `#{}` | `#{voter_id => option_id}` applied at resolution for absentees |
| `delegation` | `map()` | `#{}` | `#{delegator_id => delegate_id}` |

`match_id`, `match_pid` and `eligible` are also config keys, but the session
server supplies all three.

## Voting methods

**Plurality.** Each player picks one option; most votes wins. Ties go to
`tie_breaker`.

**Approval.** Each player submits a list of options they approve of; highest
total approval wins. Good for "avoid the worst option".

**Weighted.** Each vote is multiplied by the voter's weight. Voters absent from
the `weights` map count as 1.

```erlang
#{method => ~"weighted", weights => #{~"player1" => 3, ~"player2" => 1}}
```

**Ranked.** Each player submits a ranked list. The option with the fewest
first-choice votes is eliminated each round and its votes transfer to the next
preference, until one option has a majority. Clients send a list for
`option_id`:

```json
{"type": "vote.cast", "payload": {"vote_id": "...", "option_id": ["jungle", "caves", "volcano"]}}
```

Live tallies show first-choice counts; the final result is the winner after all
elimination rounds.

## Window types

Every type has `window_ms` as a hard upper bound.

| `window_type` | Closes when |
|---|---|
| `"fixed"` | `window_ms` elapses. Simple and predictable |
| `"ready_up"` | Every eligible voter has voted, or `window_ms` elapses |
| `"hybrid"` | As `ready_up`, but not before `min_window_ms` |
| `"adaptive"` | On reaching `supermajority` the remaining time shrinks to 3 seconds, giving latecomers a last chance. A later cast that breaks the supermajority does not restore the original window - the shortened timer keeps running |

## Spectator voting

Spectators are a separate pool merged with player votes:

```erlang
#{spectators => [~"spec1", ~"spec2"], spectator_weight => 0.3}
```

Both pools are tallied independently, normalised, then merged:

```
score = player_normalised * (1 - spectator_weight) + spectator_normalised * spectator_weight
```

For an audience-decides vote, set `eligible => []` and
`spectator_weight => 1.0`.

## Async voting

For games where not everyone is online at once.

**Quorum.** `#{quorum => 0.5}` requires half the eligible voters to
participate. Short of that, the result carries `winner => undefined` and
`status => "no_quorum"`.

**Default votes.** `#{default_votes => #{~"player2" => ~"opt_b"}}` applies a
fallback at resolution time only. Defaults never count as active votes during
the window, and an explicit vote overrides them.

**Delegation.** `#{delegation => #{~"player3" => ~"player1"}}` makes player3's
vote follow player1's at resolution time. If the delegate did not vote either,
no vote is added.

## Vote templates

Reusable configurations in app config. Per-call config overrides the template:

```erlang
{asobi, [
    {vote_templates, #{
        ~"boon_pick"   => #{method => ~"plurality", window_ms => 15000, visibility => ~"live"},
        ~"path_choice" => #{method => ~"approval", window_ms => 20000, visibility => ~"hidden"}
    }}
]}
```

```erlang
asobi_match_server:start_vote(MatchPid, #{template => ~"boon_pick", options => Options}).
```

## Reacting to the result

<!-- tabs -->
**Lua**
```lua
function vote_resolved(template, result, state)
  if template == "path_choice" then
    state.current_path = result.winner
  end
  return state
end
```
**Erlang**
```erlang
vote_resolved(~"path_choice", #{winner := WinnerId}, GameState) ->
    {ok, GameState#{current_path => WinnerId}}.
```
<!-- /tabs -->

The callback is optional. Without it the vote still runs and broadcasts, the
game just does not react server-side.

The Lua form works for a **match** script only. The world bridge does not
export `vote_resolved/3`, so a Lua world script's `vote_resolved` is never
called; an Erlang world module's is.

## Majority tyranny mitigations

**Frustration accumulator.** A player who votes for the losing option
accumulates frustration; on the next vote their weight becomes
`1 + frustration_count * frustration_bonus`, and winning resets it to 0. Three
consecutive losses give a weight of 2.5. `frustration_bonus` defaults to `0.5`
and the merged weights are attached to every vote the session starts, but only
`method => "weighted"` reads them - plurality, approval and ranked count
ballots, not weights. So the accumulator is armed by default and inert until a
vote asks for weighting.

**Supermajority requirement.** `require_supermajority => true` with a
`supermajority` threshold. If no option reaches it, the result carries
`winner => undefined` and `status => "no_consensus"`, and `vote_resolved`
decides what happens next.

**Veto tokens.** `veto_tokens_per_player` defaults to `0`, which disables veto
tokens. A player spends one with the `vote.veto` frame, which cancels the
current vote immediately. Exhausted tokens answer `no_veto_tokens`.

`frustration_bonus` and `veto_tokens_per_player` are read from the map that
starts the **session**, not from the vote config and not from `game_modes`.
Nothing in the shipped create paths passes them: a matchmaker-spawned match and
every world get the defaults above. Only Erlang code calling
`asobi_match_sup:start_match/1` directly can set them.

```erlang
asobi_match_sup:start_match(#{
    mode                   => ~"arena",
    game_module            => my_arena,
    game_config            => #{},
    min_players            => 4,
    max_players            => 4,
    frustration_bonus      => 0,
    veto_tokens_per_player => 2
}).
```

## Client protocol

### Casting a vote

```json
{
  "type": "vote.cast",
  "cid": "v1",
  "payload": {"vote_id": "...", "option_id": "jungle"}
}
```

For approval and ranked voting, `option_id` is a list.

```json
{"type": "vote.cast_ok", "cid": "v1", "payload": {"success": true}}
```

Sending `vote.cast` again during the window replaces the previous vote, up to
`max_revotes` changes. The initial vote does not count against the limit.

### Vetoing

```json
{"type": "vote.veto", "cid": "v2", "payload": {"vote_id": "..."}}
```

```json
{"type": "vote.veto_ok", "cid": "v2", "payload": {"success": true}}
```

### Errors

Both frames answer a `{"type": "error"}` frame carrying the shared error object
plus a `reason` field.

| `reason` | `error.code` | Meaning |
|---|---|---|
| `not_in_match` | `match.not_in_match` | The connection is not joined to a match |
| `vote_not_found` | `ws.request_failed` | No live vote with that id in this session |
| `not_eligible` | `ws.request_failed` | The voter is not in the eligible or spectator pool |
| `invalid_option` | `ws.request_failed` | `option_id` is not one of the vote's options |
| `rate_limited` | `rate_limited` | `max_revotes` changes already used |
| `vote_closed` | `ws.request_failed` | The window and its 500ms grace period have passed |
| `veto_disabled` | `ws.request_failed` | `veto_enabled` is false for this vote |
| `no_veto_tokens` | `ws.request_failed` | The player has spent every veto token |

**A world player always gets `not_in_match`.** Both frames route on the
session's `match_pid`, and joining a world sets `world_pid` instead, so a world
vote can be started and broadcast but not cast from a client today. This is the
same defect class as the Lua config above. Report both if they block you.

### Grace period

Votes arriving within 500ms of the window closing are still accepted, to absorb
network latency.

## Server push frames

Shown here in the `match.` namespace; a world sends the same payloads under
`world.`.

`match.vote_start`:

```json
{
  "type": "match.vote_start",
  "payload": {
    "vote_id": "...",
    "options": [{"id": "jungle", "label": "Jungle Path"}],
    "window_ms": 15000,
    "method": "plurality"
  }
}
```

`match.vote_tally`, sent on every cast, and only with `"live"` visibility:

```json
{
  "type": "match.vote_tally",
  "payload": {
    "vote_id": "...",
    "tallies": {"jungle": 2, "volcano": 1},
    "time_remaining_ms": 8432,
    "total_votes": 3
  }
}
```

`match.vote_result`:

```json
{
  "type": "match.vote_result",
  "payload": {
    "vote_id": "...",
    "winner": "jungle",
    "counts": {"jungle": 2, "volcano": 1},
    "distribution": {"jungle": 0.666, "volcano": 0.333},
    "total_votes": 3,
    "turnout": 1.0
  }
}
```

`match.vote_vetoed`:

```json
{"type": "match.vote_vetoed", "payload": {"vote_id": "...", "vetoed_by": "player_id"}}
```

## Visibility

- `"live"` - running tallies are broadcast after each cast and included in
  state queries.
- `"hidden"` - no `vote_tally` frame is sent at all; the tallies arrive only in
  `vote_result` when the vote closes, which prevents bandwagoning.

Visibility governs the live frames only. It is not recorded on the persisted
row, so a resolved hidden vote's per-voter ballots are readable in the history
below exactly like a live one's.

## Reading vote history

There is no votes screen on the console. Two REST routes cover it, and both
read the `votes` table, which is written **only when a vote resolves** - a vote
in progress appears in neither.

Every vote for a match, most recent 50, newest first:

```bash
curl http://localhost:8084/api/v1/matches/<match_id>/votes \
  -H 'Authorization: Bearer <token>'
```

```json
{"votes": [{"id": "...", "match_id": "...", "template": "...", "method": "plurality", "options": [], "votes_cast": {}, "result": {}, "distribution": {}, "turnout": 1.0, "eligible_count": 3, "window_ms": 15000, "opened_at": "...", "closed_at": "...", "inserted_at": "..."}]}
```

Restricted to participants of that match: anyone else gets `403 forbidden`.
A world's votes are stored under the world id in the same `match_id` column, so
the same route takes a world id - but only after the world finishes and writes
its record, and only for the players still in it at that moment. While the
world is live the participant check finds neither a record nor a match server
and answers `403`.

One vote by id:

```bash
curl http://localhost:8084/api/v1/votes/<vote_id> \
  -H 'Authorization: Bearer <token>'
```

Unknown ids answer `404 vote.not_found`. This route is authenticated but not
participant-scoped. See [Operator console](console.md) for what the console
does cover.

## Next steps

- [WebSocket protocol](websocket-protocol.md) - the frame envelope.
- [Phases](phases.md) - run a vote to decide what the next phase does.
- [Configuration](configuration.md) - vote templates.
