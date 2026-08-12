-module(asobi_ops_audit).
-moduledoc """
Core-wrapped audit for ops-plane mutations (ADR 0007).

`mutation/4` runs the operation and writes the row from the operation's own
return value. A call site therefore cannot forget to audit and cannot
misreport the outcome, which is the whole point: the console's broadcast
handler used to pass a hand-built `{ok, SentTo}` to its logger while the
backing function had silently dropped every failed insert, so a
half-delivered broadcast was recorded as a success.

## The outcome contract

    {ok, Succeeded, Failed} | {error, Reason}

`Succeeded` and `Failed` are lists of subjects the operation acted on -
`Failed` entries carry their reason. A single-subject mutation is the
one-element case, not a different contract, so nothing has to widen later
when the first bulk endpoint lands. The stored `outcome` column is `ok`,
`partial` or `error`, which is what makes "show me everything that did not
fully succeed" an index scan rather than a jsonb parse.

`{error, Reason}` is the operation that never got as far as having subjects -
a rejected parameter, a lost connection.

An extension ops handler returns `t:asobi_rpc:reply/0` and is audited without
translation: `{ok, Map}` is the single-subject success, and `{error, Code}`
or `{error, Code, Details}` is an operation that failed as a whole. The
stored reason is the code; `Details` is the caller's diagnostic and already
went to the caller.

## When the audit write itself fails

**The audit never fails the operation.** It runs after the mutation has
already happened, so refusing the response cannot undo a ban or un-send a
notification; it would only invite a retry that applies the change twice.
A write-ahead row could fail closed, but it would record intent rather than
outcome, and outcome - specifically partial failure - is what ADR 0007 asks
for.

The cost of that choice is paid where it is cheapest: a failed insert is
re-emitted at error level with every field the row would have carried, so
the record degrades from queryable to greppable rather than disappearing.
Nothing is dropped silently. A raise inside the audit path is caught for the
same reason - the audit must not be able to fail an operation that already
happened.

**Erasure is the stated exception**, and `record_strict/4` is how it is taken.
An erasure destroys the data it is about, so the row is the only surviving
evidence the request was honoured; there is no degraded-but-still-there state
for it to fall back to. `record_strict/4` reports whether the insert landed so
the caller can write it inside its own transaction and roll the erasure back
when it did not. Nothing else should use it.

Successful writes are not also logged. The row is the record, and mirroring
it into logs would double the retention surface holding player ids for no
new information.

A mutation that raises is audited as an error and then re-raised with its
original stacktrace. A crash is an outcome, and the plane should not be able
to hide one by exploding.
""".

-include_lib("kernel/include/logger.hrl").

-export([mutation/4, record/4, record_strict/4]).

-type subject() :: binary().
-type failure() :: {subject(), term()}.
-type outcome() :: {ok, [subject()], [failure()]} | {error, term()} | asobi_rpc:reply().
-type target() :: {binary(), subject() | undefined} | undefined.

-export_type([subject/0, failure/0, outcome/0, target/0]).

%% Bounds on the diagnostic `details` payload. An operator picks the fan-out
%% size, so an unbounded failure list is a lever for an oversized jsonb value
%% (asobi#169, asobi#216) - and the counts, not the list, are what anyone
%% queries.
-define(MAX_DETAIL_FAILURES, 50).
-define(MAX_REASON_BYTES, 200).

-doc """
Run `Fun` and audit whatever it returns.

Returns `Fun`'s own value unchanged, so wrapping a call site is a
substitution rather than a rewrite.
""".
-spec mutation(asobi_ops_auth:actor(), binary(), target(), fun(() -> outcome())) -> outcome().
mutation(Actor, Action, Target, Fun) ->
    try Fun() of
        Outcome ->
            record(Actor, Action, Target, Outcome),
            Outcome
    catch
        Class:Reason:Stack ->
            record(Actor, Action, Target, {error, {Class, Reason}}),
            erlang:raise(Class, Reason, Stack)
    end.

-doc """
Write one audit row for an outcome the caller already has.

Prefer `mutation/4`. This exists for a call site that performs its own
sequencing and genuinely holds the real outcome; it can still be handed a
lie, which `mutation/4` cannot.
""".
-spec record(asobi_ops_auth:actor(), binary(), target(), outcome()) -> ok.
record(Actor, Action, Target, Outcome) ->
    %% Never let the audit path itself decide the fate of the operation it
    %% describes: a raise here - a lost connection, an unexpected reason term -
    %% would turn a completed mutation into a 500 the caller would retry.
    try write(Actor, Action, Target, Outcome) of
        ok -> ok
    catch
        Class:Reason:Stack ->
            ?LOG_ERROR(#{
                msg => ~"ops audit row not written",
                action => Action,
                class => Class,
                reason => Reason,
                stacktrace => Stack
            }),
            ok
    end.

-doc """
Write one audit row and say whether it landed.

For `m:asobi_player_erase` only, and the reason is in the moduledoc: an
erasure's audit row is the only evidence left that the request was honoured,
so it commits with the erasure or the erasure does not happen. Every other
call site wants `mutation/4`, which cannot fail the operation it describes.
""".
-spec record_strict(asobi_ops_auth:actor(), binary(), target(), outcome()) -> ok | {error, term()}.
record_strict(Actor, Action, Target, Outcome) ->
    Params = params(Actor, Action, Target, Outcome),
    CS = kura_changeset:cast(asobi_ops_audit_entry, #{}, Params, maps:keys(Params)),
    case asobi_repo:insert(CS) of
        {ok, _Row} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec write(asobi_ops_auth:actor(), binary(), target(), outcome()) -> ok.
write(Actor, Action, Target, Outcome) ->
    Params = params(Actor, Action, Target, Outcome),
    CS = kura_changeset:cast(
        asobi_ops_audit_entry, #{}, Params, maps:keys(Params)
    ),
    case asobi_repo:insert(CS) of
        {ok, _Row} ->
            ok;
        {error, Reason} ->
            ?LOG_ERROR((loggable(Params))#{
                msg => ~"ops audit row not persisted",
                reason => Reason
            }),
            ok
    end.

%% The row's own field names, so a grep for the lost row reads the same as a
%% query for a stored one. `occurred_at` is rendered because a calendar
%% datetime tuple does not survive a JSON log formatter.
-spec loggable(map()) -> map().
loggable(#{occurred_at := {{Y, Mo, D}, {H, Mi, S}}} = Params) ->
    Rendered = iolist_to_binary(
        io_lib:format("~4..0b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0bZ", [Y, Mo, D, H, Mi, S])
    ),
    Params#{occurred_at => Rendered}.

-spec params(asobi_ops_auth:actor(), binary(), target(), outcome()) -> map().
params(Actor, Action, Target, Outcome) ->
    #{
        id := ActorId,
        display := Display,
        source := Source,
        attested := Attested
    } = Actor,
    {SucceededCount, FailedCount} = counts(Outcome),
    Base = #{
        actor_id => ActorId,
        actor_display => Display,
        actor_source => atom_to_binary(Source),
        actor_attested => Attested,
        action => Action,
        outcome => classify(Outcome),
        succeeded_count => SucceededCount,
        failed_count => FailedCount,
        details => details(Outcome),
        occurred_at => calendar:universal_time()
    },
    maps:merge(Base, target(Target)).

%% An absent target is an absent key rather than an `undefined` value: the
%% cast would reject the atom, and a missing column reads back as NULL, which
%% is what "this action had no single subject" means.
-spec target(target()) -> map().
target(undefined) -> #{};
target({Type, undefined}) -> #{target_type => Type};
target({Type, Id}) -> #{target_type => Type, target_id => Id}.

-spec counts(outcome()) -> {non_neg_integer(), non_neg_integer()}.
counts({ok, Succeeded, Failed}) -> {length(Succeeded), length(Failed)};
counts({ok, Result}) when is_map(Result) -> {1, 0};
counts({error, _Reason}) -> {0, 0};
counts({error, _Code, _Details}) -> {0, 0}.

%% A bulk call where every subject failed is not a partial success. It is
%% recorded as `error` so the "did not fully succeed" query and the "nothing
%% happened" query are answerable separately.
-spec classify(outcome()) -> binary().
classify({ok, _Succeeded, []}) -> ~"ok";
classify({ok, [], [_ | _]}) -> ~"error";
classify({ok, [_ | _], [_ | _]}) -> ~"partial";
classify({ok, Result}) when is_map(Result) -> ~"ok";
classify({error, _Reason}) -> ~"error";
classify({error, _Code, _Details}) -> ~"error".

-spec details(outcome()) -> map().
details({ok, _Succeeded, []}) ->
    #{};
details({ok, _Succeeded, Failed}) ->
    Shown = lists:sublist(Failed, ?MAX_DETAIL_FAILURES),
    #{
        failures => [
            #{subject => Subject, reason => reason(Reason)}
         || {Subject, Reason} <- Shown
        ],
        failures_omitted => length(Failed) - length(Shown)
    };
details({ok, Result}) when is_map(Result) ->
    #{};
details({error, Reason}) ->
    #{reason => reason(Reason)};
details({error, Code, _Details}) ->
    #{reason => reason(Code)}.

-spec reason(term()) -> binary().
reason(Reason) when is_binary(Reason) ->
    truncate(Reason);
reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason(Reason) ->
    truncate(iolist_to_binary(io_lib:format("~0p", [Reason]))).

-spec truncate(binary()) -> binary().
truncate(Bin) when byte_size(Bin) =< ?MAX_REASON_BYTES -> Bin;
truncate(Bin) -> <<(binary:part(Bin, 0, ?MAX_REASON_BYTES))/binary, "...">>.
