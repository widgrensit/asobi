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
| `match_id`     | `binary()`     | required       | Parent match ID                    |
| `match_pid`    | `pid()`        | required       | Match server process               |
| `options`      | `[map()]`      | required       | List of `#{id, label}` option maps |
| `eligible`     | `[binary()]`   | `[]`           | Eligible voter IDs                 |
| `window_ms`    | `pos_integer()`| `15000`        | Vote window in milliseconds        |
| `method`       | `binary()`     | `"plurality"`  | `"plurality"` or `"approval"`      |
| `visibility`   | `binary()`     | `"live"`       | `"live"` or `"hidden"`             |
| `tie_breaker`  | `binary()`     | `"random"`     | `"random"` or `"first"`            |
| `veto_enabled` | `boolean()`    | `false`        | Allow eligible voters to veto      |
| `template`     | `binary()`     | `"default"`    | Template name for analytics        |
| `vote_id`      | `binary()`     | auto-generated | Override vote ID                   |

## Vote methods

- **Plurality**: each voter picks one option, highest count wins.
- **Approval**: each voter submits a list of approved option IDs, highest
  approval count wins.

## Grace period

Late votes arriving within 500ms after the window closes are still accepted
to compensate for network latency.
""".
-behaviour(gen_statem).

-export([start_link/1, cast_vote/3, cast_veto/2, get_state/1]).
-export([callback_mode/0, init/1, terminate/3]).
-export([open/3, closed/3]).

-define(GRACE_MS, 500).

%% --- Public API ---

-doc "Start a vote server with the given config. See moduledoc for config keys.".
-spec start_link(map()) -> {ok, pid()}.
start_link(Config) ->
    gen_statem:start_link(?MODULE, Config, []).

-doc "Cast a vote. Replaces any previous vote by the same voter during the window.".
-spec cast_vote(pid(), binary(), binary()) -> ok | {error, term()}.
cast_vote(Pid, VoterId, OptionId) ->
    gen_statem:call(Pid, {cast_vote, VoterId, OptionId}).

-doc "Veto the vote (immediately cancels it). Only works if `veto_enabled` is true.".
-spec cast_veto(pid(), binary()) -> ok | {error, term()}.
cast_veto(Pid, VoterId) ->
    gen_statem:call(Pid, {veto, VoterId}).

-doc "Return the current vote state including status, options, tallies (if live), and time remaining.".
-spec get_state(pid()) -> map().
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

%% --- gen_statem callbacks ---

-spec callback_mode() -> [atom()].
callback_mode() -> [state_functions, state_enter].

-spec init(map()) -> {ok, open, map()}.
init(Config) ->
    VoteId = maps:get(vote_id, Config, asobi_id:generate()),
    MatchId = maps:get(match_id, Config),
    Template = maps:get(template, Config, ~"default"),
    Options = maps:get(options, Config),
    Eligible = maps:get(eligible, Config, []),
    WindowMs = maps:get(window_ms, Config, 15000),
    Method = maps:get(method, Config, ~"plurality"),
    Visibility = maps:get(visibility, Config, ~"live"),
    TieBreaker = maps:get(tie_breaker, Config, ~"random"),
    VetoEnabled = maps:get(veto_enabled, Config, false),
    MatchPid = maps:get(match_pid, Config),
    State = #{
        vote_id => VoteId,
        match_id => MatchId,
        match_pid => MatchPid,
        template => Template,
        options => Options,
        eligible => sets:from_list(Eligible, [{version, 2}]),
        eligible_list => Eligible,
        window_ms => WindowMs,
        method => Method,
        visibility => Visibility,
        tie_breaker => TieBreaker,
        veto_enabled => VetoEnabled,
        votes => #{},
        vetoed => false,
        opened_at => erlang:system_time(millisecond)
    },
    broadcast_vote_start(State),
    {ok, open, State}.

%% --- open state ---

-spec open(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
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

-spec closed(gen_statem:event_type(), term(), map()) -> gen_statem:state_enter_result(atom()).
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
    From, VoterId, OptionId, #{eligible := Eligible, options := Options, votes := Votes} = State
) ->
    IsEligible = sets:is_element(VoterId, Eligible),
    ValidOption = validate_option(OptionId, Options),
    case {IsEligible, ValidOption} of
        {false, _} ->
            {keep_state_and_data, [{reply, From, {error, not_eligible}}]};
        {_, false} ->
            {keep_state_and_data, [{reply, From, {error, invalid_option}}]};
        {true, true} ->
            Votes1 = Votes#{VoterId => OptionId},
            State1 = State#{votes => Votes1},
            maybe_broadcast_tally(State1),
            {keep_state, State1, [{reply, From, ok}]}
    end.

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
    #{votes := Votes, options := Options, method := Method, tie_breaker := TieBreaker} = State
) ->
    Result = tally(Method, Votes, Options, TieBreaker),
    State1 = State#{
        result => Result,
        closed_at => erlang:system_time(millisecond)
    },
    broadcast_vote_result(State1),
    persist_vote(State1),
    _ = notify_match(resolved, State1),
    {stop, normal, State1}.

tally(~"plurality", Votes, Options, TieBreaker) ->
    Counts = lists:foldl(
        fun(#{id := Id}, Acc) -> Acc#{Id => 0} end,
        #{},
        Options
    ),
    Counts1 = maps:fold(
        fun(_VoterId, OptionId, Acc) ->
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
tally(~"approval", Votes, Options, TieBreaker) ->
    %% In approval voting, each vote value is a list of approved option IDs
    Counts = lists:foldl(
        fun(#{id := Id}, Acc) -> Acc#{Id => 0} end,
        #{},
        Options
    ),
    Counts1 = maps:fold(
        fun
            (_VoterId, Approved, Acc) when is_list(Approved) ->
                lists:foldl(
                    fun(OptId, InnerAcc) ->
                        InnerAcc#{OptId => maps:get(OptId, InnerAcc, 0) + 1}
                    end,
                    Acc,
                    Approved
                );
            (_VoterId, OptionId, Acc) ->
                Acc#{OptionId => maps:get(OptionId, Acc, 0) + 1}
        end,
        Counts,
        Votes
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
tally(_Method, Votes, Options, TieBreaker) ->
    %% Fallback to plurality
    tally(~"plurality", Votes, Options, TieBreaker).

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
    opened_at := OpenedAt,
    window_ms := WindowMs
}) ->
    Now = erlang:system_time(millisecond),
    Remaining = max(0, (OpenedAt + WindowMs) - Now),
    Counts = maps:fold(
        fun(_VoterId, OptionId, Acc) ->
            Acc#{OptionId => maps:get(OptionId, Acc, 0) + 1}
        end,
        lists:foldl(fun(#{id := Id}, Acc) -> Acc#{Id => 0} end, #{}, Options),
        Votes
    ),
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
    match_pid := MatchPid, vote_id := VoteId, template := Template, result := Result
}) ->
    MatchPid ! {vote_resolved, VoteId, Template, Result};
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
            Counts = maps:fold(
                fun(_VoterId, OptionId, Acc) ->
                    Acc#{OptionId => maps:get(OptionId, Acc, 0) + 1}
                end,
                lists:foldl(fun(#{id := Id}, Acc) -> Acc#{Id => 0} end, #{}, Options),
                Votes
            ),
            Base#{tallies => Counts};
        _ ->
            Base
    end.
