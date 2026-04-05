-module(asobi_vote_server).
-moduledoc """
Vote lifecycle state machine.

Manages a single vote instance within a match. States flow `open` -> `closed`
(with automatic resolution on close). Supports plurality and approval voting
methods, configurable timed windows, live or hidden tallies, veto, and
tie-breaking.

## Config keys

| Key            | Type           | Default        | Description                        |
|----------------|----------------|----------------|------------------------------------|
| `match_id`       | `binary()`     | required       | Parent match ID                    |
| `match_pid`      | `pid()`        | required       | Match server process               |
| `options`        | `[map()]`      | required       | List of `#{id, label}` option maps |
| `eligible`       | `[binary()]`   | `[]`           | Eligible voter IDs                 |
| `window_ms`      | `pos_integer()`| `15000`        | Vote window in milliseconds        |
| `method`         | `binary()`     | `"plurality"`  | `"plurality"`, `"approval"`, `"weighted"`, or `"ranked"` |
| `visibility`     | `binary()`     | `"live"`       | `"live"` or `"hidden"`             |
| `tie_breaker`    | `binary()`     | `"random"`     | `"random"` or `"first"`            |
| `veto_enabled`   | `boolean()`    | `false`        | Allow eligible voters to veto      |
| `template`       | `binary()`     | `"default"`    | Template name (resolved from app config if defined) |
| `vote_id`        | `binary()`     | auto-generated | Override vote ID                   |
| `weights`        | `map()`        | `#{}`          | Voter weights for `"weighted"` method: `#{voter_id => number()}` |
| `max_revotes`    | `pos_integer()`| `3`            | Max times a voter can change their vote |
| `window_type`    | `binary()`     | `"fixed"`      | `"fixed"`, `"ready_up"`, `"hybrid"`, or `"adaptive"` |
| `min_window_ms`  | `pos_integer()`| `5000`         | Minimum window for `"hybrid"` mode |
| `supermajority`  | `float()`      | `0.75`         | Threshold for `"adaptive"` early close |
| `require_supermajority` | `boolean()` | `false`     | If true, winner must reach `supermajority` threshold or result is no-consensus |
| `spectators`     | `[binary()]`   | `[]`           | Spectator voter IDs (separate pool) |
| `spectator_weight` | `float()`    | `0.3`          | Weight ratio for spectator votes (0.0-1.0) |
| `quorum`         | `float()`      | `0.0`          | Min fraction of eligible voters needed (0.0 = disabled) |
| `default_votes`  | `map()`        | `#{}`          | Default option per voter if they don't vote: `#{voter_id => option_id}` |
| `delegation`     | `map()`        | `#{}`          | Vote delegation: `#{delegator_id => delegate_id}` |

## Vote templates

Define reusable templates in app config. Per-call config overrides template defaults:

```erlang
{asobi, [{vote_templates, #{
    ~"boon_pick" => #{method => ~"plurality", window_ms => 15000, visibility => ~"live"},
    ~"path_choice" => #{method => ~"approval", window_ms => 20000, visibility => ~"hidden"}
}}]}
```

## Vote methods

- **Plurality**: each voter picks one option, highest count wins.
- **Approval**: each voter submits a list of approved option IDs, highest
  approval count wins.
- **Weighted**: like plurality, but each vote is multiplied by the voter's
  weight from the `weights` map. Unweighted voters default to 1.
- **Ranked**: each voter submits a ranked list `[first_choice, second, ...]`.
  Iterative elimination: lowest first-choice option eliminated, its votes
  redistributed to next preference, until one option has majority.

## Spectator voting

Spectators are a separate voter pool. Their tallies are merged with player
tallies using `spectator_weight` (default 0.3 = 30% influence). Set
`spectators` list and optionally `spectator_weight`.

## Async voting

For non-real-time games. Set `quorum` (0.0-1.0) to resolve early when
enough voters participate. Use `default_votes` for absent players and
`delegation` to let a player's vote follow another's.

## Window types

- **Fixed** (default): vote runs for exactly `window_ms`, then closes.
- **Ready-up**: closes as soon as all eligible voters have cast a vote,
  or when `window_ms` expires (whichever comes first).
- **Hybrid**: like ready-up, but enforces a minimum `min_window_ms` before
  early close is allowed. Prevents snap decisions.
- **Adaptive**: starts with `window_ms`, but when a supermajority threshold
  is reached, the remaining time shrinks to 3 seconds (giving others a
  last chance). Resets if supermajority is lost.

## Grace period

Late votes arriving within 500ms after the window closes are still accepted
to compensate for network latency.
""".
-behaviour(gen_statem).

-export([start_link/1, cast_vote/3, cast_veto/2, get_state/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([open/3, closed/3]).

-define(GRACE_MS, 500).
-define(DEFAULT_MAX_REVOTES, 3).
-define(ADAPTIVE_SHRINK_MS, 3000).

%% --- Public API ---

-doc "Start a vote server with the given config. See moduledoc for config keys.".
-spec start_link(map()) -> gen_statem:start_ret().
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-doc "Cast a vote. Replaces any previous vote by the same voter during the window.".
-spec cast_vote(pid(), binary(), binary() | [binary()]) -> ok | {error, term()}.
cast_vote(Pid, VoterId, OptionId) ->
    case gen_statem:call(Pid, {cast_vote, VoterId, OptionId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-doc "Veto the vote (immediately cancels it). Only works if `veto_enabled` is true.".
-spec cast_veto(pid(), binary()) -> ok | {error, term()}.
cast_veto(Pid, VoterId) ->
    case gen_statem:call(Pid, {veto, VoterId}) of
        ok -> ok;
        {error, _} = Err -> Err
    end.

-doc "Return the current vote state including status, options, tallies (if live), and time remaining.".
-spec get_state(pid()) -> map().
get_state(Pid) ->
    case gen_statem:call(Pid, get_state) of
        S when is_map(S) -> S;
        _ -> #{}
    end.

%% --- gen_statem callbacks ---

-spec callback_mode() -> gen_statem:callback_mode_result().
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> {ok, open, map()}.
init(Config) ->
    Template = maps:get(template, Config, ~"default"),
    Merged = merge_template(Template, Config),
    VoteId = maps:get(vote_id, Merged, asobi_id:generate()),
    MatchId = maps:get(match_id, Merged),
    Options = maps:get(options, Merged),
    Eligible = maps:get(eligible, Merged, []),
    WindowMs = maps:get(window_ms, Merged, 15000),
    Method = maps:get(method, Merged, ~"plurality"),
    Visibility = maps:get(visibility, Merged, ~"live"),
    TieBreaker = maps:get(tie_breaker, Merged, ~"random"),
    VetoEnabled = maps:get(veto_enabled, Merged, false),
    Weights = maps:get(weights, Merged, #{}),
    MaxRevotes = maps:get(max_revotes, Merged, ?DEFAULT_MAX_REVOTES),
    WindowType = maps:get(window_type, Merged, ~"fixed"),
    MinWindowMs = maps:get(min_window_ms, Merged, 5000),
    Supermajority = maps:get(supermajority, Merged, 0.75),
    RequireSupermajority = maps:get(require_supermajority, Merged, false),
    Spectators = maps:get(spectators, Merged, []),
    SpectatorWeight = maps:get(spectator_weight, Merged, 0.3),
    Quorum = maps:get(quorum, Merged, 0.0),
    DefaultVotes = maps:get(default_votes, Merged, #{}),
    Delegation = maps:get(delegation, Merged, #{}),
    MatchPid = maps:get(match_pid, Merged),
    AllEligible = Eligible ++ Spectators,
    State = #{
        vote_id => VoteId,
        match_id => MatchId,
        match_pid => MatchPid,
        template => Template,
        options => Options,
        eligible => sets:from_list(AllEligible, [{version, 2}]),
        eligible_list => Eligible,
        eligible_count => length(Eligible),
        spectators => sets:from_list(Spectators, [{version, 2}]),
        spectator_list => Spectators,
        spectator_weight => SpectatorWeight,
        quorum => Quorum,
        default_votes => DefaultVotes,
        delegation => Delegation,
        window_ms => WindowMs,
        window_type => WindowType,
        min_window_ms => MinWindowMs,
        supermajority => Supermajority,
        require_supermajority => RequireSupermajority,
        method => Method,
        visibility => Visibility,
        tie_breaker => TieBreaker,
        veto_enabled => VetoEnabled,
        weights => Weights,
        max_revotes => MaxRevotes,
        votes => #{},
        vote_counts => #{},
        vetoed => false,
        opened_at => erlang:system_time(millisecond)
    },
    asobi_telemetry:vote_started(maps:get(vote_id, State), maps:get(method, State, ~"unknown")),
    broadcast_vote_start(State),
    {ok, open, State}.

%% --- open state ---

-spec open(gen_statem:event_type() | enter, term(), map()) -> gen_statem:state_enter_result(atom()).
open(enter, _OldState, #{window_ms := WindowMs}) ->
    {keep_state_and_data, [{state_timeout, WindowMs, window_expired}]};
open({call, From}, {cast_vote, VoterId, OptionId}, State) ->
    handle_cast_vote(From, VoterId, OptionId, State);
open({call, From}, {veto, VoterId}, #{veto_enabled := true} = State) ->
    handle_veto(From, VoterId, State);
open({call, From}, {veto, _VoterId}, _State) ->
    {keep_state_and_data, [{reply, From, {error, veto_disabled}}]};
open({call, From}, get_state, State) ->
    {keep_state_and_data, [{reply, From, external_state(open, State)}]};
open(state_timeout, window_expired, State) ->
    {next_state, closed, State}.

%% --- closed state ---

-spec closed(gen_statem:event_type() | enter, term(), map()) ->
    gen_statem:state_enter_result(atom()).
closed(enter, _OldState, State) ->
    resolve_and_stop(State);
closed({call, From}, {cast_vote, VoterId, OptionId}, State) ->
    %% Grace period: accept if within GRACE_MS of window close
    Now = erlang:system_time(millisecond),
    OpenedAt = maps:get(opened_at, State),
    WindowMs = maps:get(window_ms, State),
    case Now - (OpenedAt + WindowMs) =< ?GRACE_MS of
        true -> handle_cast_vote(From, VoterId, OptionId, State);
        false -> {keep_state_and_data, [{reply, From, {error, vote_closed}}]}
    end;
closed({call, From}, get_state, State) ->
    {keep_state_and_data, [{reply, From, external_state(closed, State)}]};
closed({call, From}, _, _State) ->
    {keep_state_and_data, [{reply, From, {error, vote_closed}}]}.

-spec terminate(term(), atom(), map()) -> ok.
terminate(_Reason, _StateName, _State) ->
    ok.

%% --- Internal ---

handle_cast_vote(
    From,
    VoterId,
    OptionId,
    #{
        eligible := Eligible,
        options := Options,
        votes := Votes,
        vote_counts := VoteCounts,
        max_revotes := MaxRevotes
    } =
        State
) ->
    IsEligible = sets:is_element(VoterId, Eligible),
    ValidOption = validate_option(OptionId, Options),
    PriorCount = maps:get(VoterId, VoteCounts, 0),
    HasPriorVote = maps:is_key(VoterId, Votes),
    RateLimited = HasPriorVote andalso PriorCount >= MaxRevotes,
    case {IsEligible, ValidOption, RateLimited} of
        {false, _, _} ->
            {keep_state_and_data, [{reply, From, {error, not_eligible}}]};
        {_, false, _} ->
            {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
        {_, _, true} ->
            {keep_state_and_data, [{reply, From, {error, rate_limited}}]};
        {true, true, false} ->
            asobi_telemetry:vote_cast(maps:get(vote_id, State), VoterId),
            Votes1 = Votes#{VoterId => OptionId},
            NewCount =
                case HasPriorVote of
                    true -> PriorCount + 1;
                    false -> 0
                end,
            VoteCounts1 = VoteCounts#{VoterId => NewCount},
            State1 = State#{votes => Votes1, vote_counts => VoteCounts1},
            maybe_broadcast_tally(State1),
            maybe_early_close(From, State1)
    end.

maybe_early_close(
    From, #{window_type := ~"ready_up", votes := Votes, eligible_count := EC} = State
) ->
    case maps:size(Votes) >= EC of
        true -> {next_state, closed, State, [{reply, From, ok}]};
        false -> {keep_state, State, [{reply, From, ok}]}
    end;
maybe_early_close(
    From,
    #{
        window_type := ~"hybrid",
        votes := Votes,
        eligible_count := EC,
        min_window_ms := MinMs,
        opened_at := OpenedAt
    } = State
) ->
    AllVoted = maps:size(Votes) >= EC,
    Now = erlang:system_time(millisecond),
    MinElapsed = (Now - OpenedAt) >= MinMs,
    case AllVoted andalso MinElapsed of
        true -> {next_state, closed, State, [{reply, From, ok}]};
        false -> {keep_state, State, [{reply, From, ok}]}
    end;
maybe_early_close(
    From,
    #{
        window_type := ~"adaptive",
        votes := Votes,
        supermajority := Threshold,
        options := Options,
        method := Method,
        weights := Weights,
        opened_at := OpenedAt,
        window_ms := WindowMs
    } = State
) ->
    Tallies = compute_live_tallies(Method, Votes, Options, Weights),
    TotalVotes = maps:size(Votes),
    HasSupermajority = TotalVotes > 0 andalso check_supermajority(Tallies, TotalVotes, Threshold),
    case HasSupermajority of
        true ->
            Now = erlang:system_time(millisecond),
            Elapsed = Now - OpenedAt,
            OriginalRemaining = max(0, WindowMs - Elapsed),
            ShrunkRemaining = min(OriginalRemaining, ?ADAPTIVE_SHRINK_MS),
            {keep_state, State, [
                {reply, From, ok}, {state_timeout, ShrunkRemaining, window_expired}
            ]};
        false ->
            {keep_state, State, [{reply, From, ok}]}
    end;
maybe_early_close(From, State) ->
    {keep_state, State, [{reply, From, ok}]}.

check_supermajority(Tallies, TotalVotes, Threshold) ->
    MaxCount = lists:max(maps:values(Tallies)),
    is_number(MaxCount) andalso is_number(TotalVotes) andalso TotalVotes > 0 andalso
        MaxCount / TotalVotes >= Threshold.

validate_option(OptionIds, Options) when is_list(OptionIds) ->
    OptionSet = sets:from_list([Id || #{id := Id} <- Options], [{version, 2}]),
    lists:all(fun(Id) -> sets:is_element(Id, OptionSet) end, OptionIds);
validate_option(OptionId, Options) ->
    lists:any(fun(#{id := Id}) -> Id =:= OptionId end, Options).

handle_veto(From, VoterId, #{eligible := Eligible} = State) ->
    case sets:is_element(VoterId, Eligible) of
        false ->
            {keep_state_and_data, [{reply, From, {error, not_eligible}}]};
        true ->
            State1 = State#{vetoed => true, vetoed_by => VoterId},
            broadcast_vote_vetoed(State1),
            _ = notify_match(vetoed, State1),
            {stop_and_reply, normal, [{reply, From, ok}], State1}
    end.

resolve_and_stop(
    #{
        votes := Votes,
        options := Options,
        method := Method,
        tie_breaker := TieBreaker,
        weights := Weights,
        require_supermajority := RequireSM,
        supermajority := SMThreshold,
        eligible_list := EligibleList,
        spectators := SpectatorsSet,
        spectator_weight := SpectatorW,
        quorum := Quorum,
        default_votes := DefaultVotes,
        delegation := Delegation
    } =
        State
) ->
    %% Apply delegation and defaults for absent voters
    FinalVotes = apply_delegation_and_defaults(Votes, EligibleList, Delegation, DefaultVotes),
    %% Check quorum
    VoterCount = maps:size(FinalVotes),
    EligibleCount = length(EligibleList),
    QuorumMet =
        Quorum =< 0.0 orelse EligibleCount =:= 0 orelse VoterCount / EligibleCount >= Quorum,
    RawResult =
        case QuorumMet of
            false ->
                #{
                    winner => undefined,
                    status => ~"no_quorum",
                    counts => #{},
                    total_votes => VoterCount
                };
            true ->
                %% Split player and spectator votes
                {PlayerVotes, SpectatorVotes} = split_spectator_votes(FinalVotes, SpectatorsSet),
                case maps:size(SpectatorVotes) of
                    0 ->
                        tally(Method, PlayerVotes, Options, TieBreaker, Weights);
                    _ ->
                        merge_spectator_result(
                            tally(Method, PlayerVotes, Options, TieBreaker, Weights),
                            tally(Method, SpectatorVotes, Options, TieBreaker, Weights),
                            SpectatorW,
                            Options,
                            TieBreaker
                        )
                end
        end,
    Result = maybe_enforce_supermajority(RawResult, RequireSM, SMThreshold),
    State1 = State#{
        result => Result,
        closed_at => erlang:system_time(millisecond)
    },
    DurationMs = maps:get(closed_at, State1) - maps:get(opened_at, State1, 0),
    asobi_telemetry:vote_resolved(maps:get(vote_id, State1), DurationMs, Result),
    broadcast_vote_result(State1),
    persist_vote(State1),
    _ = notify_match(resolved, State1),
    {stop, normal, State1}.

tally(~"plurality", Votes, Options, TieBreaker, _Weights) ->
    Counts = init_counts(Options),
    Counts1 = maps:fold(
        fun(_VoterId, OptionId, Acc) when is_map(Acc) ->
            Acc#{OptionId => maps:get(OptionId, Acc, 0) + 1}
        end,
        Counts,
        Votes
    ),
    TotalVotes = maps:size(Votes),
    Distribution = maps:map(
        fun(_Id, Count) ->
            case TotalVotes of
                0 -> 0.0;
                _ -> Count / TotalVotes
            end
        end,
        Counts1
    ),
    MaxCount = lists:max([0 | maps:values(Counts1)]),
    Winners = maps:keys(maps:filter(fun(_Id, C) -> C =:= MaxCount end, Counts1)),
    Winner = break_tie(Winners, TieBreaker),
    #{
        winner => Winner,
        counts => Counts1,
        distribution => Distribution,
        total_votes => TotalVotes
    };
tally(~"approval", Votes, Options, TieBreaker, _Weights) ->
    Counts = init_counts(Options),
    Counts1 = ensure_map(
        maps:fold(
            fun
                (_VoterId, Approved, Acc) when is_list(Approved), is_map(Acc) ->
                    ensure_map(
                        lists:foldl(
                            fun(OptId, InnerAcc) when is_map(InnerAcc) ->
                                Cur = get_count(OptId, InnerAcc),
                                InnerAcc#{OptId => Cur + 1}
                            end,
                            Acc,
                            Approved
                        )
                    );
                (_VoterId, OptionId, Acc) when is_map(Acc) ->
                    Cur = get_count(OptionId, Acc),
                    Acc#{OptionId => Cur + 1}
            end,
            Counts,
            Votes
        )
    ),
    TotalVotes = maps:size(Votes),
    MaxCount = lists:max([0 | maps:values(Counts1)]),
    Winners = maps:keys(maps:filter(fun(_Id, C) -> C =:= MaxCount end, Counts1)),
    Winner = break_tie(Winners, TieBreaker),
    #{
        winner => Winner,
        counts => Counts1,
        total_votes => TotalVotes
    };
tally(~"weighted", Votes, Options, TieBreaker, Weights) ->
    Counts = init_counts_float(Options),
    Counts1 = maps:fold(
        fun(VoterId, OptionId, Acc) when is_map(Acc) ->
            W = maps:get(VoterId, Weights, 1),
            Acc#{OptionId => maps:get(OptionId, Acc, 0.0) + W}
        end,
        Counts,
        Votes
    ),
    TotalVotes = maps:size(Votes),
    TotalWeight = maps:fold(
        fun(_Id, W, Sum) -> Sum + W end,
        0.0,
        Counts1
    ),
    Distribution = maps:map(
        fun(_Id, W) ->
            case TotalWeight of
                +0.0 -> 0.0;
                _ -> W / TotalWeight
            end
        end,
        Counts1
    ),
    MaxCount = lists:max([0.0 | maps:values(Counts1)]),
    Winners = maps:keys(maps:filter(fun(_Id, C) -> C =:= MaxCount end, Counts1)),
    Winner = break_tie(Winners, TieBreaker),
    #{
        winner => Winner,
        counts => Counts1,
        distribution => Distribution,
        total_votes => TotalVotes
    };
tally(~"ranked", Votes, Options, TieBreaker, _Weights) ->
    TotalVotes = maps:size(Votes),
    OptionIds = [Id || #{id := Id} <- Options],
    Winner = ranked_eliminate(Votes, OptionIds, TieBreaker),
    Counts = init_counts(Options),
    FirstChoiceCounts = maps:fold(
        fun
            (_VoterId, [First | _], Acc) -> Acc#{First => maps:get(First, Acc, 0) + 1};
            (_VoterId, _, Acc) -> Acc
        end,
        Counts,
        Votes
    ),
    #{
        winner => Winner,
        counts => FirstChoiceCounts,
        total_votes => TotalVotes
    };
tally(_Method, Votes, Options, TieBreaker, Weights) ->
    tally(~"plurality", Votes, Options, TieBreaker, Weights).

ranked_eliminate(_Votes, [Single], _TieBreaker) ->
    Single;
ranked_eliminate(_Votes, [], _TieBreaker) ->
    undefined;
ranked_eliminate(Votes, Remaining, TieBreaker) ->
    RemainingSet = sets:from_list(Remaining, [{version, 2}]),
    InitCounts = lists:foldl(fun(Id, Acc) when is_map(Acc) -> Acc#{Id => 0} end, #{}, Remaining),
    FirstChoicesRaw = maps:fold(
        fun
            (_VoterId, Ranking, Acc) when is_list(Ranking), is_map(Acc) ->
                case first_valid(Ranking, RemainingSet) of
                    undefined -> Acc;
                    Choice -> Acc#{Choice => get_count(Choice, Acc) + 1}
                end;
            (_VoterId, _, Acc) ->
                Acc
        end,
        case InitCounts of
            IC when is_map(IC) -> IC
        end,
        Votes
    ),
    FirstChoices =
        case FirstChoicesRaw of
            FC when is_map(FC) -> FC;
            _ -> #{}
        end,
    TotalVotes = lists:sum([Val || Val <- maps:values(FirstChoices), is_number(Val)]),
    Majority = TotalVotes / 2,
    {MaxC, MaxId} = maps:fold(
        fun
            (Id, Count, {BestC, _BestId}) when is_number(Count), Count > BestC -> {Count, Id};
            (_Id, _Count, Best) -> Best
        end,
        {0, undefined},
        FirstChoices
    ),
    case MaxC > Majority of
        true ->
            MaxId;
        false ->
            MinCount = lists:min(maps:values(FirstChoices)),
            Losers = maps:keys(
                maps:filter(fun(_Id, Count) -> Count =:= MinCount end, FirstChoices)
            ),
            Eliminated = break_tie(Losers, TieBreaker),
            ranked_eliminate(Votes, Remaining -- [Eliminated], TieBreaker)
    end.

first_valid([], _Set) ->
    undefined;
first_valid([H | T], Set) ->
    case sets:is_element(H, Set) of
        true -> H;
        false -> first_valid(T, Set)
    end.

maybe_enforce_supermajority(Result, false, _Threshold) ->
    Result;
maybe_enforce_supermajority(#{winner := undefined} = Result, true, _Threshold) ->
    Result;
maybe_enforce_supermajority(
    #{winner := Winner, counts := Counts, total_votes := TotalVotes} = Result, true, Threshold
) ->
    WinnerCount = maps:get(Winner, Counts, 0),
    case TotalVotes > 0 andalso WinnerCount / TotalVotes >= Threshold of
        true ->
            Result;
        false ->
            Result#{winner => undefined, status => ~"no_consensus"}
    end.

apply_delegation_and_defaults(Votes, EligibleList, Delegation, DefaultVotes) ->
    lists:foldl(
        fun(PlayerId, Acc) when is_map(Acc) ->
            case maps:is_key(PlayerId, Acc) of
                true ->
                    Acc;
                false ->
                    case maps:get(PlayerId, Delegation, undefined) of
                        undefined ->
                            case maps:get(PlayerId, DefaultVotes, undefined) of
                                undefined -> Acc;
                                Default -> Acc#{PlayerId => Default}
                            end;
                        DelegateId ->
                            case maps:get(DelegateId, Acc, undefined) of
                                undefined -> Acc;
                                DelegateVote -> Acc#{PlayerId => DelegateVote}
                            end
                    end
            end
        end,
        Votes,
        EligibleList
    ).

split_spectator_votes(Votes, SpectatorsSet) ->
    maps:fold(
        fun(VoterId, Vote, {PAcc, SAcc}) ->
            case sets:is_element(VoterId, SpectatorsSet) of
                true -> {PAcc, SAcc#{VoterId => Vote}};
                false -> {PAcc#{VoterId => Vote}, SAcc}
            end
        end,
        {#{}, #{}},
        Votes
    ).

merge_spectator_result(PlayerResult, SpectatorResult, SpectatorW, Options, TieBreaker) ->
    PlayerW = 1.0 - SpectatorW,
    PCounts = maps:get(counts, PlayerResult, init_counts(Options)),
    SCounts = maps:get(counts, SpectatorResult, init_counts(Options)),
    PTotalRaw = lists:sum([V || V <- maps:values(PCounts), is_number(V)]),
    STotalRaw = lists:sum([V || V <- maps:values(SCounts), is_number(V)]),
    MergedCounts = ensure_map(
        lists:foldl(
            fun(#{id := Id}, Acc) when is_map(Acc) ->
                PNorm =
                    case PTotalRaw of
                        0 -> 0.0;
                        _ -> maps:get(Id, PCounts, 0) / PTotalRaw
                    end,
                SNorm =
                    case STotalRaw of
                        0 -> 0.0;
                        _ -> maps:get(Id, SCounts, 0) / STotalRaw
                    end,
                Acc#{Id => PNorm * PlayerW + SNorm * SpectatorW}
            end,
            #{},
            Options
        )
    ),
    MaxScore = lists:max([0.0 | maps:values(MergedCounts)]),
    Winners = maps:keys(maps:filter(fun(_Id, S) -> S =:= MaxScore end, MergedCounts)),
    Winner = break_tie(Winners, TieBreaker),
    TotalVotes = maps:get(total_votes, PlayerResult, 0) + maps:get(total_votes, SpectatorResult, 0),
    #{
        winner => Winner,
        counts => MergedCounts,
        distribution => MergedCounts,
        total_votes => TotalVotes,
        player_counts => PCounts,
        spectator_counts => SCounts
    }.

init_counts(Options) ->
    lists:foldl(fun(#{id := Id}, Acc) when is_map(Acc) -> Acc#{Id => 0} end, #{}, Options).

init_counts_float(Options) ->
    lists:foldl(fun(#{id := Id}, Acc) when is_map(Acc) -> Acc#{Id => 0.0} end, #{}, Options).

merge_template(Template, Config) ->
    Templates = ensure_map(application:get_env(asobi, vote_templates, #{})),
    case Templates of
        #{Template := Defaults} when is_map(Defaults) -> maps:merge(Defaults, Config);
        _ -> Config
    end.

-spec ensure_map(term()) -> #{term() => term()}.
ensure_map(M) when is_map(M) -> M;
ensure_map(_) -> #{}.

-spec get_count(term(), map()) -> number().
get_count(Key, Map) ->
    case maps:get(Key, Map, 0) of
        N when is_number(N) -> N;
        _ -> 0
    end.

break_tie([Single], _TieBreaker) ->
    Single;
break_tie([], _TieBreaker) ->
    undefined;
break_tie(Winners, ~"random") ->
    lists:nth(rand:uniform(length(Winners)), Winners);
break_tie([First | _], ~"first") ->
    First;
break_tie(Winners, _) ->
    lists:nth(rand:uniform(length(Winners)), Winners).

maybe_broadcast_tally(#{visibility := ~"live"} = State) ->
    broadcast_vote_tally(State);
maybe_broadcast_tally(_State) ->
    ok.

broadcast_vote_start(#{
    match_pid := MatchPid,
    vote_id := VoteId,
    options := Options,
    window_ms := WindowMs,
    method := Method
}) ->
    Payload = #{
        vote_id => VoteId,
        options => Options,
        window_ms => WindowMs,
        method => Method
    },
    asobi_match_server:broadcast_event(MatchPid, vote_start, Payload).

broadcast_vote_tally(#{
    match_pid := MatchPid,
    vote_id := VoteId,
    votes := Votes,
    options := Options,
    method := Method,
    weights := Weights,
    opened_at := OpenedAt,
    window_ms := WindowMs
}) ->
    Now = erlang:system_time(millisecond),
    Remaining = max(0, (OpenedAt + WindowMs) - Now),
    Counts = compute_live_tallies(Method, Votes, Options, Weights),
    Payload = #{
        vote_id => VoteId,
        tallies => Counts,
        time_remaining_ms => Remaining,
        total_votes => maps:size(Votes)
    },
    asobi_match_server:broadcast_event(MatchPid, vote_tally, Payload).

broadcast_vote_result(#{
    match_pid := MatchPid,
    vote_id := VoteId,
    result := Result,
    eligible_list := Eligible,
    votes := Votes
}) ->
    EligibleCount = length(Eligible),
    VoteCount = maps:size(Votes),
    Turnout =
        case EligibleCount of
            0 -> 0.0;
            _ -> VoteCount / EligibleCount
        end,
    Payload = #{
        vote_id => VoteId,
        winner => maps:get(winner, Result),
        distribution => maps:get(distribution, Result, #{}),
        counts => maps:get(counts, Result),
        total_votes => VoteCount,
        turnout => Turnout
    },
    asobi_match_server:broadcast_event(MatchPid, vote_result, Payload).

broadcast_vote_vetoed(#{match_pid := MatchPid, vote_id := VoteId, vetoed_by := VetoedBy}) ->
    Payload = #{vote_id => VoteId, vetoed_by => VetoedBy},
    asobi_match_server:broadcast_event(MatchPid, vote_vetoed, Payload).

notify_match(resolved, #{
    match_pid := MatchPid, vote_id := VoteId, template := Template, result := Result, votes := Votes
}) ->
    MatchPid ! {vote_resolved, VoteId, Template, Result#{votes_cast => Votes}};
notify_match(vetoed, #{match_pid := MatchPid, vote_id := VoteId, template := Template}) ->
    MatchPid ! {vote_vetoed, VoteId, Template}.

persist_vote(#{
    vote_id := VoteId,
    match_id := MatchId,
    template := Template,
    method := Method,
    options := Options,
    votes := Votes,
    result := Result,
    eligible_list := Eligible,
    window_ms := WindowMs,
    opened_at := OpenedAt,
    closed_at := ClosedAt
}) ->
    EligibleCount = length(Eligible),
    VoteCount = maps:size(Votes),
    Turnout =
        case EligibleCount of
            0 -> 0.0;
            _ -> VoteCount / EligibleCount
        end,
    CS = kura_changeset:cast(
        asobi_vote,
        #{},
        #{
            id => VoteId,
            match_id => MatchId,
            template => Template,
            method => Method,
            options => Options,
            votes_cast => Votes,
            result => Result,
            distribution => maps:get(distribution, Result, #{}),
            turnout => Turnout,
            eligible_count => EligibleCount,
            window_ms => WindowMs,
            opened_at => OpenedAt,
            closed_at => ClosedAt
        },
        [
            id,
            match_id,
            template,
            method,
            options,
            votes_cast,
            result,
            distribution,
            turnout,
            eligible_count,
            window_ms,
            opened_at,
            closed_at
        ]
    ),
    case asobi_repo:insert(CS) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            logger:warning(#{msg => ~"failed to persist vote", vote_id => VoteId, reason => Reason}),
            ok
    end.

external_state(Status, #{
    vote_id := VoteId,
    options := Options,
    method := Method,
    visibility := Visibility,
    weights := Weights,
    votes := Votes,
    opened_at := OpenedAt,
    window_ms := WindowMs
}) ->
    Now = erlang:system_time(millisecond),
    Remaining = max(0, (OpenedAt + WindowMs) - Now),
    Base = #{
        vote_id => VoteId,
        status => Status,
        options => Options,
        method => Method,
        total_votes => maps:size(Votes),
        time_remaining_ms => Remaining
    },
    case Visibility of
        ~"live" ->
            Counts = compute_live_tallies(Method, Votes, Options, Weights),
            Base#{tallies => Counts};
        _ ->
            Base
    end.

compute_live_tallies(~"ranked", Votes, Options, _Weights) ->
    maps:fold(
        fun
            (_VoterId, [First | _], Acc) when is_map(Acc) ->
                Acc#{First => maps:get(First, Acc, 0) + 1};
            (_VoterId, _, Acc) ->
                Acc
        end,
        init_counts(Options),
        Votes
    );
compute_live_tallies(~"weighted", Votes, Options, Weights) ->
    maps:fold(
        fun(VoterId, OptionId, Acc) when is_map(Acc) ->
            W = maps:get(VoterId, Weights, 1),
            Acc#{OptionId => maps:get(OptionId, Acc, 0.0) + W}
        end,
        init_counts_float(Options),
        Votes
    );
compute_live_tallies(_Method, Votes, Options, _Weights) ->
    maps:fold(
        fun(_VoterId, OptionId, Acc) when is_map(Acc) ->
            Acc#{OptionId => maps:get(OptionId, Acc, 0) + 1}
        end,
        init_counts(Options),
        Votes
    ).
