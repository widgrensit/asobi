-module(asobi_ops_controller).
-moduledoc """
HTTP surface of the ops read plane.

Every list endpoint here returns the same envelope, clamps its own paging, and
rejects a sort field it does not recognise with 400 rather than ordering by
something the caller did not ask for.

These routes are mounted behind `asobi_auth_plugin:verify/1`, the same
player-scoped bearer check the rest of `/api/v1` uses. That is a placeholder,
not the destination: ops calls want an operator capability, which is ADR 0007
and a follow-up PR. Until then every projection here is held to exactly what
the equivalent public endpoint already exposes.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([players/1, matches/1, features/1]).

-type response() :: {json, map()} | {json, integer(), map(), map()}.

-spec players(cowboy_req:req()) -> response().
players(Req) ->
    list(Req, fun asobi_ops_players:query/1, fun asobi_ops_players:project/1).

-spec matches(cowboy_req:req()) -> response().
matches(Req) ->
    list(Req, fun asobi_ops_matches:query/1, fun asobi_ops_matches:project/1).

-spec features(cowboy_req:req()) -> response().
features(_Req) ->
    {json, asobi_ops_features:features()}.

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
            {json, 400, #{}, error_body(Reason)}
    end.

-spec page(#kura_query{}, asobi_ops_params:page_spec(), fun((map()) -> map())) -> response().
page(Query, PageSpec, Project) ->
    case asobi_ops_page:list(Query, PageSpec, Project) of
        {ok, Envelope} ->
            {json, Envelope};
        {error, Reason} ->
            ?LOG_ERROR(#{msg => ~"ops list query failed", reason => Reason}),
            {json, 500, #{}, #{error => ~"query_failed"}}
    end.

-spec params(cowboy_req:req()) -> asobi_ops_params:params().
params(#{parsed_qs := Params}) when is_map(Params) -> Params;
params(_Req) -> #{}.

-spec error_body(term()) -> map().
error_body({unknown_sort, Field}) -> #{error => ~"unknown_sort_field", field => Field};
error_body({unknown_order, Order}) -> #{error => ~"unknown_sort_order", order => Order};
error_body(_) -> #{error => ~"bad_request"}.
