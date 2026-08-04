-module(asobi_ops_controller).
-moduledoc """
HTTP surface of the ops read plane.

Every list endpoint here returns the same envelope, clamps its own paging, and
rejects a sort field it does not recognise with 400 rather than ordering by
something the caller did not ask for.

These routes are mounted behind `asobi_ops_auth:verify/1`, the operator
capability check (ADR 0007) - never the player-scoped bearer check the rest of
`/api/v1` uses, which would let any authenticated player, guest included,
enumerate the deployment. Every projection here is still held to exactly what
the equivalent public endpoint already exposes.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([players/1, player/1, matches/1, match/1, features/1]).
-export([leaderboards/1, leaderboard_entries/1, matchmaker/1]).
-export([economy_items/1, economy_item/1, economy_listings/1, economy_listing/1]).
-export([chat_channels/1, chat_messages/1]).
-export([tournaments/1, tournament/1, notifications/1]).

-type response() ::
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

%% `leaderboard_id` is a VARCHAR(255); a longer binding matches no board, so
%% it is answered as a bad request rather than paid for as a query.
-define(MAX_BOARD_ID_BYTES, 255).

%% `channel_id` is the same VARCHAR(255), and the same reasoning.
-define(MAX_CHANNEL_ID_BYTES, 255).

-spec players(cowboy_req:req()) -> response().
players(Req) ->
    list(Req, fun asobi_ops_players:query/1, fun asobi_ops_players:project/1).

-spec player(cowboy_req:req()) -> response().
player(Req) ->
    lookup(Req, asobi_player, fun asobi_ops_players:project/1).

-spec matches(cowboy_req:req()) -> response().
matches(Req) ->
    list(Req, fun asobi_ops_matches:query/1, fun asobi_ops_matches:project/1).

-spec match(cowboy_req:req()) -> response().
match(Req) ->
    lookup(Req, asobi_match_record, fun asobi_ops_matches:project/1).

-spec economy_items(cowboy_req:req()) -> response().
economy_items(Req) ->
    list(Req, fun asobi_ops_economy:items_query/1, fun asobi_ops_economy:project_item/1).

-spec economy_item(cowboy_req:req()) -> response().
economy_item(Req) ->
    lookup(Req, asobi_item_def, fun asobi_ops_economy:project_item/1).

-spec economy_listings(cowboy_req:req()) -> response().
economy_listings(Req) ->
    list(Req, fun asobi_ops_economy:listings_query/1, fun asobi_ops_economy:project_listing/1).

-spec economy_listing(cowboy_req:req()) -> response().
economy_listing(Req) ->
    lookup(Req, asobi_store_listing, fun asobi_ops_economy:project_listing/1).

-spec tournaments(cowboy_req:req()) -> response().
tournaments(Req) ->
    list(Req, fun asobi_ops_tournaments:query/1, fun asobi_ops_tournaments:project/1).

-spec tournament(cowboy_req:req()) -> response().
tournament(Req) ->
    lookup(Req, asobi_tournament, fun asobi_ops_tournaments:project/1).

-spec notifications(cowboy_req:req()) -> response().
notifications(Req) ->
    list(Req, fun asobi_ops_notifications:query/1, fun asobi_ops_notifications:project/1).

-spec chat_channels(cowboy_req:req()) -> response().
chat_channels(Req) ->
    rows(Req, fun asobi_ops_chat:channels/1, fun asobi_ops_chat:project_channel/1).

%% The channel id is a free-form string, not a uuid, so it is bounded rather
%% than shape-checked.
-spec chat_messages(cowboy_req:req()) -> response().
chat_messages(#{bindings := #{~"id" := ChannelId}} = Req) when
    is_binary(ChannelId), ChannelId =/= ~"", byte_size(ChannelId) =< ?MAX_CHANNEL_ID_BYTES
->
    list(
        Req,
        fun(Params) -> asobi_ops_chat:messages_query(ChannelId, Params) end,
        fun asobi_ops_chat:project_message/1
    );
chat_messages(_Req) ->
    {asobi_error, ~"ops.invalid_id"}.

-spec features(cowboy_req:req()) -> response().
features(_Req) ->
    {json, asobi_ops_features:features()}.

-spec leaderboards(cowboy_req:req()) -> response().
leaderboards(Req) ->
    rows(Req, fun asobi_ops_leaderboards:boards/1, fun asobi_ops_leaderboards:project_board/1).

-spec leaderboard_entries(cowboy_req:req()) -> response().
leaderboard_entries(#{bindings := #{~"id" := BoardId}} = Req) when
    is_binary(BoardId), BoardId =/= ~"", byte_size(BoardId) =< ?MAX_BOARD_ID_BYTES
->
    list(
        Req,
        fun(Params) -> asobi_ops_leaderboards:entries_query(BoardId, Params) end,
        fun asobi_ops_leaderboards:project_entry/1
    );
leaderboard_entries(_Req) ->
    {asobi_error, ~"ops.invalid_board_id"}.

%% The snapshot is read once and used for both halves of the response, so the
%% totals and the rows can never describe two different samples.
-spec matchmaker(cowboy_req:req()) -> response().
matchmaker(Req) ->
    Params = params(Req),
    Snapshot = asobi_matchmaker:snapshot(),
    case asobi_ops_matchmaker:rows(Snapshot, Params) of
        {ok, {Rows, Orders}} ->
            Envelope = asobi_ops_page:slice(
                Rows,
                Orders,
                asobi_ops_params:page(Params),
                fun asobi_ops_matchmaker:project/1
            ),
            {json, Envelope#{queue => asobi_ops_matchmaker:summary(Snapshot)}};
        {error, Reason} ->
            error_response(Reason)
    end.

-spec list(
    cowboy_req:req(),
    fun((asobi_ops_params:params()) -> {ok, #kura_query{}} | {error, term()}),
    fun((map()) -> map())
) -> response().
list(Req, BuildQuery, Project) ->
    Params = params(Req),
    case BuildQuery(Params) of
        {ok, Query} ->
            page(Query, asobi_ops_params:page(Params), Project);
        {error, Reason} ->
            error_response(Reason)
    end.

%% The single-row envelope: `{"data": {...}}`, the list envelope minus the
%% `page` key it has nothing to report. A console reads `data` either way.
-spec lookup(cowboy_req:req(), module(), fun((map()) -> map())) -> response().
lookup(#{bindings := #{~"id" := Id}}, Schema, Project) ->
    case asobi_ops_lookup:fetch(Schema, Id, Project) of
        {ok, Row} -> {json, #{data => Row}};
        {error, Reason} -> error_response(Reason)
    end;
lookup(_Req, _Schema, _Project) ->
    {asobi_error, ~"ops.invalid_id"}.

-spec rows(
    cowboy_req:req(),
    fun(
        (asobi_ops_params:params()) ->
            {ok, {[map()], asobi_ops_params:sort_spec()}} | {error, term()}
    ),
    fun((map()) -> map())
) -> response().
rows(Req, BuildRows, Project) ->
    Params = params(Req),
    case BuildRows(Params) of
        {ok, {Rows, Orders}} ->
            {json, asobi_ops_page:slice(Rows, Orders, asobi_ops_params:page(Params), Project)};
        {error, Reason} ->
            error_response(Reason)
    end.

-spec page(#kura_query{}, asobi_ops_params:page_spec(), fun((map()) -> map())) -> response().
page(Query, PageSpec, Project) ->
    case asobi_ops_page:list(Query, PageSpec, Project) of
        {ok, Envelope} -> {json, Envelope};
        {error, Reason} -> error_response({query_failed, Reason})
    end.

-spec params(cowboy_req:req()) -> asobi_ops_params:params().
params(#{parsed_qs := Params}) when is_map(Params) -> Params;
params(_Req) -> #{}.

%% A rejected parameter is the caller's fault and says which one; a failed
%% read is ours and says nothing beyond that, with the reason in the log.
%%
%% `field` and `order` were top-level keys before the shared object existed
%% and stay there; they are the object's `details` too. Both are echoed back
%% from the caller's own query string, so neither can become a code.
-spec error_response(term()) -> response().
error_response({unknown_sort, Field}) ->
    asobi_error:legacy(~"ops.unknown_sort_field", #{field => Field});
error_response({unknown_order, Order}) ->
    asobi_error:legacy(~"ops.unknown_sort_order", #{order => Order});
error_response({invalid_filter, Field}) ->
    {asobi_error, ~"ops.invalid_filter", #{field => Field}};
error_response(invalid_id) ->
    {asobi_error, ~"ops.invalid_id"};
error_response(not_found) ->
    {asobi_error, ~"ops.not_found"};
error_response({query_failed, Reason}) ->
    ?LOG_ERROR(#{msg => ~"ops list query failed", reason => Reason}),
    {asobi_error, ~"ops.query_failed"};
error_response(_) ->
    {asobi_error, ~"invalid_payload"}.
