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

-export([players/1, matches/1, features/1, leaderboards/1, leaderboard_entries/1, matchmaker/1]).

-type response() :: {json, map()} | {json, integer(), map(), map()}.

%% `leaderboard_id` is a VARCHAR(255); a longer binding matches no board, so
%% it is answered as a bad request rather than paid for as a query.
-define(MAX_BOARD_ID_BYTES, 255).

-spec players(cowboy_req:req()) -> response().
players(Req) ->
    list(Req, fun asobi_ops_players:query/1, fun asobi_ops_players:project/1).

-spec matches(cowboy_req:req()) -> response().
matches(Req) ->
    list(Req, fun asobi_ops_matches:query/1, fun asobi_ops_matches:project/1).

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
    {json, 400, #{}, #{error => ~"invalid_board_id"}}.

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
-spec error_response(term()) -> response().
error_response({unknown_sort, Field}) ->
    {json, 400, #{}, #{error => ~"unknown_sort_field", field => Field}};
error_response({unknown_order, Order}) ->
    {json, 400, #{}, #{error => ~"unknown_sort_order", order => Order}};
error_response({query_failed, Reason}) ->
    ?LOG_ERROR(#{msg => ~"ops list query failed", reason => Reason}),
    {json, 500, #{}, #{error => ~"query_failed"}};
error_response(_) ->
    {json, 400, #{}, #{error => ~"bad_request"}}.
