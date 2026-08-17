-module(asobi_guest_env).
-moduledoc """
Guest settings read from the environment, for deployments that run a release
rather than write a `sys.config`.

The sibling of `m:asobi_console_env`, and it exists for the same reason: relx
substitutes `${VAR}` into `sys.config` before the VM starts, which is fine for
a value that is always set and fatal for one that is not. An unset variable
leaves the literal `${VAR}` in the file and the node does not boot. Reading the
environment here instead means a missing variable is simply a missing variable,
the key stays optional, and a self-hoster who does write a `sys.config` is
unaffected - an OS variable overrides it only when set.

## `ASOBI_GUEST_REAP_AFTER`

Seconds of inactivity before `m:asobi_guest_reaper` erases an unclaimed guest.
The reaper reads the key with `application:get_env/3` at sweep time rather than
at start, so a value set here is live on the next tick.

**Anything that is not a positive integer leaves the key unset**, which the
reaper reads as "permanent guests". Absent, empty, `0`, negative, a float, a
word - one answer, and it deletes nobody.

That is the only safe direction for a fail case. A guessed default would mean a
node that could not parse its own configuration erasing player accounts on a
schedule nobody chose; the sweep writes no audit rows, so there would be no
record of it either. `0` is the explicit "off" a managed deployment sends, so
the value travels as a number rather than as an empty string something could
mangle.

Setting it back to off must actually turn the sweeper off, so an unparseable or
absent value *unsets* the key rather than leaving whatever an earlier boot put
there.
""".

-include_lib("kernel/include/logger.hrl").

-export([apply/0]).

-define(REAP_AFTER, "ASOBI_GUEST_REAP_AFTER").
-define(IS_SPACE(C), (C =:= $\s orelse C =:= $\t orelse C =:= $\n orelse C =:= $\r)).

-doc "Fold the guest environment variables into `asobi`'s application env.".
-spec apply() -> ok.
apply() ->
    ok = set_reap_after().

-spec set_reap_after() -> ok.
set_reap_after() ->
    case seconds(os:getenv(?REAP_AFTER)) of
        {ok, Seconds} ->
            application:set_env(asobi, guest_reap_after, Seconds),
            ?LOG_INFO(#{msg => ~"guest_retention_applied", reap_after_seconds => Seconds});
        off ->
            %% Unset rather than set to something falsy: the reaper keys
            %% "never" on the absence of the key, and a stale value from an
            %% earlier boot of the same node must not survive a policy change
            %% back to off.
            application:unset_env(asobi, guest_reap_after),
            ?LOG_INFO(#{msg => ~"guest_retention_off", detail => detail(os:getenv(?REAP_AFTER))})
    end,
    ok.

-spec seconds(string() | false) -> {ok, pos_integer()} | off.
seconds(false) ->
    off;
seconds(Value) ->
    try list_to_integer(trim(Value)) of
        Seconds when Seconds > 0 -> {ok, Seconds};
        _NonPositive -> off
    catch
        error:badarg -> off
    end.

%% Not `string:trim/1`, which is typed to return a charlist and so cannot be
%% handed to `list_to_integer/1` without a cast. A value typed by hand into a
%% deployment field picks up a stray space often enough to be worth tolerating,
%% and tolerating it keeps the failure direction unchanged: anything this does
%% not turn into a positive integer still means "keep everyone".
-spec trim(string()) -> string().
trim(Value) ->
    trailing(leading(Value)).

-spec leading(string()) -> string().
leading([C | Rest]) when ?IS_SPACE(C) -> leading(Rest);
leading(Value) -> Value.

%% Recursive rather than a `lists:reverse/1` round trip, which eqwalizer widens
%% to `[term()]` and then refuses to hand back to `list_to_integer/1`.
-spec trailing(string()) -> string().
trailing([]) ->
    [];
trailing([C | Rest]) ->
    case trailing(Rest) of
        [] when ?IS_SPACE(C) -> [];
        Trimmed -> [C | Trimmed]
    end.

%% A malformed value and an absent one produce the same behaviour but not the
%% same cause, and only one of them is somebody's mistake.
-spec detail(string() | false) -> binary().
detail(false) ->
    ~"no ASOBI_GUEST_REAP_AFTER set - unclaimed guests are kept for ever";
detail("0") ->
    ~"ASOBI_GUEST_REAP_AFTER is 0 - unclaimed guests are kept for ever";
detail(_Other) ->
    ~"ASOBI_GUEST_REAP_AFTER is not a positive integer - unclaimed guests are kept for ever".
