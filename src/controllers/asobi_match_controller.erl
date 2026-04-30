-module(asobi_match_controller).

-export([show/1, index/1]).

-spec show(cowboy_req:req()) -> {json, map()} | {status, integer()}.
show(#{bindings := #{~"id" := MatchId}} = _Req) ->
    case asobi_repo:get(asobi_match_record, MatchId) of
        {ok, Record} -> {json, Record};
        {error, not_found} -> {status, 404}
    end.

-spec index(cowboy_req:req()) -> {json, map()}.
index(#{qs := Qs} = _Req) when is_binary(Qs) ->
    Params = cow_qs:parse_qs(Qs),
    Q0 = kura_query:from(asobi_match_record),
    Q1 =
        case proplists:get_value(~"mode", Params) of
            undefined -> Q0;
            Mode -> kura_query:where(Q0, {mode, Mode})
        end,
    Q2 =
        case proplists:get_value(~"status", Params) of
            undefined -> Q1;
            Status -> kura_query:where(Q1, {status, Status})
        end,
    Limit = asobi_qs:integer(~"limit", Params, 50, 1, 200),
    Q3 = kura_query:limit(kura_query:order_by(Q2, [{inserted_at, desc}]), Limit),
    {ok, Records} = asobi_repo:all(Q3),
    {json, #{matches => Records}}.
