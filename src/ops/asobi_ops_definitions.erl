-module(asobi_ops_definitions).
-moduledoc """
Creating the definitions an operator authors: item defs, store listings and
tournaments. The `config` half of the ops write plane (ADR 0007).

These are the mutations ADR 0007 puts on the other side of the line from ban
and grant - "economy definitions, credentials, deploy-adjacent settings". A
deployment can hand out a credential that publishes a store without also
handing out the ability to ban a player, and the split is enforced by the
class tag on the route rather than by convention.

## Going through the schema, not around it

Each create runs the schema's own `changeset/2` - `asobi_item_def`,
`asobi_store_listing`, `asobi_tournament` - so the rarity allowlist, the
required fields and the status vocabulary are the ones the rest of core
already enforces. `asobi_admin` reimplemented these against `asobi_repo`
directly, which is how it ended up with a parallel set of rules to keep in
step; there is one set here.

The request body is passed to `kura_changeset:cast/4` as-is with an atom
allowlist. kura normalises the binary JSON keys itself, so an unlisted key is
dropped rather than cast, and a wrongly typed value becomes a field error
instead of a crash: `"start_at": "not a date"` is a 422 naming `start_at`,
not a 500.

## Two guards the schemas do not carry

`item_def_id` is shape-checked before it reaches Postgres. kura accepts any
36-byte binary as a uuid, and Postgres *raises* on one that is not - which
turns a typo into a 500.

Every jsonb field is size-checked. The body cap admits 1 MiB, and `metadata`,
`entry_fee` and `rewards` are unbounded jsonb columns underneath it; the same
per-row cap `m:asobi_player` and `m:asobi_economy` already apply (asobi#169,
asobi#216) applies here, at the one call site that can reach these columns
from a request.

## Ids

The row's id is generated here rather than by the insert, so the audit row
can carry it as `target_id` before the write is attempted. "Who created this
listing" is then the same indexed lookup as "who banned this player", instead
of a timestamp correlation against a table with no operator column.
""".

-include_lib("kura/include/kura.hrl").

-export([create_item/2, create_listing/2, create_tournament/2]).

-define(CLASS, config).

-define(ITEM_ACTION, ~"economy.item.create").
-define(ITEM_TARGET, ~"item_def").
-define(ITEM_FIELDS, [slug, name, category, rarity, stackable, metadata]).

-define(LISTING_ACTION, ~"economy.listing.create").
-define(LISTING_TARGET, ~"store_listing").
-define(LISTING_FIELDS, [item_def_id, currency, price, active, valid_from, valid_until, metadata]).

-define(TOURNAMENT_ACTION, ~"tournament.create").
-define(TOURNAMENT_TARGET, ~"tournament").
-define(TOURNAMENT_FIELDS, [
    name, leaderboard_id, max_entries, entry_fee, rewards, status, start_at, end_at, metadata
]).

-doc """
Create an item definition as `Actor`.

`{ok, [ItemId], []}` on success. The id is also the audit row's `target_id`.
""".
-spec create_item(asobi_ops_auth:actor(), map()) -> asobi_ops_audit:outcome().
create_item(Actor, Params) ->
    create(Actor, ?ITEM_ACTION, ?ITEM_TARGET, asobi_item_def, ?ITEM_FIELDS, Params, []).

-doc "Create a store listing as `Actor`.".
-spec create_listing(asobi_ops_auth:actor(), map()) -> asobi_ops_audit:outcome().
create_listing(Actor, Params) ->
    create(Actor, ?LISTING_ACTION, ?LISTING_TARGET, asobi_store_listing, ?LISTING_FIELDS, Params, [
        ~"item_def_id"
    ]).

-doc """
Create a tournament as `Actor`, and start its server process.

The process is started only after the row is committed, and its failure to
start does not fail the create: the row is the tournament, and
`m:asobi_tournament_sup` is how it is run right now.
""".
-spec create_tournament(asobi_ops_auth:actor(), map()) -> asobi_ops_audit:outcome().
create_tournament(Actor, Params) ->
    create(
        Actor,
        ?TOURNAMENT_ACTION,
        ?TOURNAMENT_TARGET,
        asobi_tournament,
        ?TOURNAMENT_FIELDS,
        Params,
        []
    ).

-spec create(
    asobi_ops_auth:actor(), binary(), binary(), module(), [atom()], map(), [binary()]
) -> asobi_ops_audit:outcome().
create(#{caps := Caps} = Actor, Action, TargetType, Schema, Fields, Params, Uuids) ->
    Id = Schema:generate_id(),
    asobi_ops_audit:mutation(Actor, Action, {TargetType, Id}, fun() ->
        case asobi_ops_caps:authorised(?CLASS, Caps) of
            true -> validated(Id, Schema, Fields, Params, Uuids);
            false -> {error, forbidden}
        end
    end).

-spec validated(binary(), module(), [atom()], map(), [binary()]) -> asobi_ops_audit:outcome().
validated(Id, Schema, Fields, Params, Uuids) ->
    case problem(Params, Uuids) of
        none -> insert(Id, Schema, Fields, Params);
        Problem -> {error, Problem}
    end.

-spec insert(binary(), module(), [atom()], map()) -> asobi_ops_audit:outcome().
insert(Id, Schema, Fields, Params) ->
    CS = kura_changeset:put_change(Schema:changeset(#{}, cast_map(Params, Fields)), id, Id),
    case asobi_repo:insert(CS) of
        {ok, Row} ->
            started(Schema, Row),
            {ok, [Id], []};
        {error, #kura_changeset{} = Invalid} ->
            {error, {invalid, kura_changeset:traverse_errors(Invalid, fun(_F, M) -> M end)}};
        {error, Reason} ->
            {ok, [], [{Id, Reason}]}
    end.

-spec started(module(), map()) -> ok.
started(asobi_tournament, Row) ->
    _ = asobi_tournament_sup:start_tournament(Row),
    ok;
started(_Schema, _Row) ->
    ok.

%% Only the allowlisted keys reach the changeset, and they reach it under the
%% binary names the request used. kura's `cast/4` normalises those to the atoms
%% in `Fields`, so an unlisted key is not merely rejected - it is never seen.
-spec cast_map(map(), [atom()]) -> map().
cast_map(Params, Fields) ->
    Names = [atom_to_binary(Field) || Field <- Fields],
    maps:with(Names, Params).

-spec problem(map(), [binary()]) -> none | {invalid, map()}.
problem(Params, Uuids) ->
    case [{Key, [~"is not a valid id"]} || Key <- Uuids, not uuid_ok(maps:get(Key, Params, ~""))] of
        [_ | _] = Bad -> {invalid, maps:from_list(Bad)};
        [] -> jsonb_problem(Params)
    end.

%% A key the caller omitted is not this check's business - `validate_required`
%% is what reports a missing one, with the message every other endpoint uses.
-spec uuid_ok(term()) -> boolean().
uuid_ok(~"") -> true;
uuid_ok(Value) -> asobi_ops_params:uuid(Value).

-spec jsonb_problem(map()) -> none | {invalid, map()}.
jsonb_problem(Params) ->
    Limit = asobi_jsonb:default_metadata_bytes(),
    Oversized = [
        {Key, [~"is larger than this column accepts"]}
     || Key <- [~"metadata", ~"entry_fee", ~"rewards"],
        is_map_key(Key, Params),
        not asobi_jsonb:within_limit(maps:get(Key, Params), Limit)
    ],
    case Oversized of
        [_ | _] -> {invalid, maps:from_list(Oversized)};
        [] -> none
    end.
