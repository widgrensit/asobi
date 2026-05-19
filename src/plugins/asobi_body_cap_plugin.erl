-module(asobi_body_cap_plugin).
-behaviour(nova_plugin).
-moduledoc """
Pre-request plugin that caps HTTP request body size.

Runs before `nova_request_plugin` so we can short-circuit oversized requests
with 413 before any body bytes are buffered into BEAM heap.

H2 (2026-05-19): without this cap, an authenticated client could POST a
multi-GB JSON body to any `/api/v1/**` endpoint and OOM the node before the
controller's per-route check (e.g. `MAX_SAVE_DATA_BYTES`) ever ran.

Options:
  max_body => non_neg_integer()      %% bytes, default 1 MiB
  require_content_length => boolean()%% reject chunked w/o content-length, default true
""".

-export([pre_request/4, post_request/4, plugin_info/0]).

-define(DEFAULT_MAX_BODY, 1048576).

-spec pre_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
pre_request(Req, _Env, Options, State) ->
    Max = maps:get(max_body, Options, ?DEFAULT_MAX_BODY),
    RequireCL = maps:get(require_content_length, Options, true),
    case needs_check(Req) of
        false ->
            {ok, Req, State};
        true ->
            check_size(Req, Max, RequireCL, State)
    end.

-spec post_request(cowboy_req:req(), map(), map(), term()) ->
    {ok, cowboy_req:req(), term()}.
post_request(Req, _Env, _Options, State) ->
    {ok, Req, State}.

-spec plugin_info() -> map().
plugin_info() ->
    #{
        title => ~"Body Size Cap",
        version => ~"1.0.0",
        url => ~"https://github.com/widgrensit/asobi",
        authors => [~"widgrensit"],
        description => ~"Rejects oversized HTTP request bodies before they are buffered"
    }.

-spec needs_check(cowboy_req:req()) -> boolean().
needs_check(Req) ->
    cowboy_req:has_body(Req).

-spec check_size(cowboy_req:req(), non_neg_integer(), boolean(), term()) ->
    {ok, cowboy_req:req(), term()} | {break, cowboy_req:req(), term()}.
check_size(Req, Max, RequireCL, State) ->
    case cowboy_req:body_length(Req) of
        undefined when RequireCL ->
            reject(411, ~"length_required", Req, State);
        undefined ->
            {ok, Req, State};
        N when is_integer(N), N > Max ->
            reject(413, ~"payload_too_large", Req, State);
        _ ->
            {ok, Req, State}
    end.

-spec reject(integer(), binary(), cowboy_req:req(), term()) ->
    {break, cowboy_req:req(), term()}.
reject(Status, Reason, Req, State) ->
    Body = json:encode(#{~"error" => Reason}),
    Req1 = cowboy_req:reply(
        Status,
        #{~"content-type" => ~"application/json"},
        Body,
        Req
    ),
    {break, Req1, State}.
