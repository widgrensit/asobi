-module(asobi_ops_write_controller).
-moduledoc """
HTTP surface of the ops write plane: the six mutations a real operator
console needs.

Three are `player_data` - ban, unban, grant currency - and three are `config`
- item definition, store listing, tournament. Every one of them is tagged in
`asobi_ops_caps:classes/0`, so a route added here without a class is denied
at run time and fails the router meta-test at build time.

This module holds no domain logic. It reads the actor the security callback
resolved, reads the body, calls the one function in `m:asobi_ops_moderation`,
`m:asobi_ops_grants` or `m:asobi_ops_definitions` that owns the mutation, and
turns that function's `t:asobi_ops_audit:outcome/0` into a response. The audit
row is written inside those functions, by the wrapper, so no path through
this module can mutate anything without leaving one.

## Reading the outcome

An outcome is not a status code, and the mapping is the interesting part:

* `{ok, [_], []}` - the mutation changed something. 201 for a create, 200
  otherwise.
* `{ok, [], []}` - the mutation succeeded and changed nothing: the ban was
  already in force, the idempotency key had already been granted. 200, with
  the response saying so, because a retry must answer the same as the call it
  is retrying.
* `{ok, [], [_ | _]}` - the write was attempted and failed. 500, reason in
  the audit row and the log, not in the body.
* `{error, _}` - nothing was attempted. The reason decides the status.
""".

-include_lib("kernel/include/logger.hrl").

-export([ban/1, unban/1, grant/1]).
-export([create_item/1, create_listing/1, create_tournament/1]).

-type response() ::
    {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

-spec ban(cowboy_req:req()) -> response().
ban(Req) ->
    moderation(Req, fun asobi_ops_moderation:ban/2, true).

-spec unban(cowboy_req:req()) -> response().
unban(Req) ->
    moderation(Req, fun asobi_ops_moderation:unban/2, false).

-spec grant(cowboy_req:req()) -> response().
grant(Req) ->
    with_player(Req, fun(Actor, PlayerId) ->
        case body(Req) of
            {ok, Params} -> granted(Actor, PlayerId, Params);
            {error, invalid_body} -> {asobi_error, ~"ops.invalid_body"}
        end
    end).

-spec create_item(cowboy_req:req()) -> response().
create_item(Req) ->
    created(Req, fun asobi_ops_definitions:create_item/2).

-spec create_listing(cowboy_req:req()) -> response().
create_listing(Req) ->
    created(Req, fun asobi_ops_definitions:create_listing/2).

-spec create_tournament(cowboy_req:req()) -> response().
create_tournament(Req) ->
    created(Req, fun asobi_ops_definitions:create_tournament/2).

-spec moderation(
    cowboy_req:req(),
    fun((asobi_ops_auth:actor(), binary()) -> asobi_ops_audit:outcome()),
    boolean()
) -> response().
moderation(Req, Fun, Banned) ->
    with_player(Req, fun(Actor, PlayerId) ->
        answer(Fun(Actor, PlayerId), 200, fun(Changed) ->
            #{player_id => PlayerId, banned => Banned, changed => Changed}
        end)
    end).

-spec granted(asobi_ops_auth:actor(), binary(), map()) -> response().
granted(Actor, PlayerId, Params) ->
    Currency = maps:get(~"currency", Params, undefined),
    Amount = maps:get(~"amount", Params, undefined),
    Key = maps:get(~"idempotency_key", Params, undefined),
    answer(asobi_ops_grants:grant(Actor, PlayerId, Currency, Amount, Key), 200, fun(Applied) ->
        #{
            player_id => PlayerId,
            currency => Currency,
            amount => Amount,
            applied => Applied
        }
    end).

-spec created(
    cowboy_req:req(), fun((asobi_ops_auth:actor(), map()) -> asobi_ops_audit:outcome())
) -> response().
created(Req, Fun) ->
    case {actor(Req), body(Req)} of
        {{ok, Actor}, {ok, Params}} -> create_response(Fun(Actor, Params));
        {{error, no_actor}, _} -> {asobi_error, ~"forbidden"};
        {_, {error, invalid_body}} -> {asobi_error, ~"ops.invalid_body"}
    end.

%% A create has nothing to report when it changed nothing, and it cannot: the
%% id is minted per request, so `{ok, [], []}` is unreachable here and is
%% treated as the failure it would be rather than answered with an empty body.
-spec create_response(asobi_ops_audit:outcome()) -> response().
create_response({ok, [Id], []}) -> {json, 201, #{}, #{data => #{id => Id}}};
create_response(Outcome) -> failure(Outcome).

-spec answer(asobi_ops_audit:outcome(), integer(), fun((boolean()) -> map())) -> response().
answer({ok, [_ | _], []}, Status, Body) -> {json, Status, #{}, #{data => Body(true)}};
answer({ok, [], []}, Status, Body) -> {json, Status, #{}, #{data => Body(false)}};
answer(Outcome, _Status, _Body) -> failure(Outcome).

-spec failure(asobi_ops_audit:outcome()) -> response().
failure({error, forbidden}) ->
    {asobi_error, ~"forbidden"};
failure({error, not_found}) ->
    {asobi_error, ~"ops.not_found"};
failure({error, invalid_idempotency_key}) ->
    {asobi_error, ~"ops.idempotency_key_required"};
failure({error, invalid_currency}) ->
    invalid(#{currency => [~"must be a non-empty currency name"]});
failure({error, invalid_amount}) ->
    invalid(#{amount => [~"must be a positive whole number within the grant cap"]});
failure({error, {invalid, Fields}}) ->
    invalid(Fields);
failure(Outcome) ->
    %% Everything left is ours: a failed write, a lost connection, a reason no
    %% clause above names. The audit row already carries it; the log line is
    %% for the reason the row truncates, and the caller is told nothing beyond
    %% "this failed".
    ?LOG_ERROR(#{msg => ~"ops mutation failed", outcome => Outcome}),
    {asobi_error, ~"ops.write_failed"}.

%% `fields` is the key every other 422 in asobi carries its per-field messages
%% under (`m:asobi_auth_error`), so a console that already parses one shape
%% does not have to learn a second. It sits in `details` and nowhere else -
%% `asobi_error:legacy/2`'s top-level copy exists for routes that predate the
%% error object, and these do not.
-spec invalid(map()) -> response().
invalid(Fields) ->
    {asobi_error, ~"validation_failed", #{fields => Fields}}.

-spec with_player(
    cowboy_req:req(), fun((asobi_ops_auth:actor(), binary()) -> response())
) -> response().
with_player(#{bindings := #{~"id" := PlayerId}} = Req, Fun) ->
    case {asobi_ops_params:uuid(PlayerId), actor(Req)} of
        {true, {ok, Actor}} -> Fun(Actor, PlayerId);
        {false, _} -> {asobi_error, ~"ops.invalid_id"};
        {_, {error, no_actor}} -> {asobi_error, ~"forbidden"}
    end;
with_player(_Req, _Fun) ->
    {asobi_error, ~"ops.invalid_id"}.

%% The security callback puts the actor here and denies the request outright
%% when it cannot resolve one, so the miss is unreachable through the router.
%% It is still answered rather than matched, because a mutation must never be
%% the thing that discovers a mis-mounted route.
-spec actor(cowboy_req:req()) -> {ok, asobi_ops_auth:actor()} | {error, no_actor}.
actor(#{auth_data := #{ops_actor := Actor}}) -> {ok, Actor};
actor(_Req) -> {error, no_actor}.

%% No body at all is an empty one: ban and unban carry nothing, and requiring
%% `{}` from them would be ceremony. A body that is not a JSON object is an
%% error rather than an empty one - `[1,2,3]` is a caller who meant something
%% and got it wrong.
-spec body(cowboy_req:req()) -> {ok, map()} | {error, invalid_body}.
body(#{json := Params}) when is_map(Params) -> {ok, Params};
body(#{json := _Other}) -> {error, invalid_body};
body(_Req) -> {ok, #{}}.
