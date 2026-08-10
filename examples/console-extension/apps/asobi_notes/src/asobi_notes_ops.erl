%% The handlers ops/0 names. Same shape as an RPC handler - (Params, Ctx) - and
%% the same reply envelope: {ok, map()} | {error, Code} | {error, Code, Details}.
%%
%% Params is the parsed query string for a `get` and the decoded JSON body for
%% a write, because that is what asobi_ops_extension reads in each case.
-module(asobi_notes_ops).

-export([list/2, add/2]).

%% A read answers the envelope core's own list routes answer - #{data, page} -
%% so the console's Pager works against it without being told anything about
%% this extension.
-spec list(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
list(Params, _Ctx) ->
    All =
        case maps:get(~"player_id", Params, ~"") of
            ~"" -> asobi_notes:all();
            PlayerId -> asobi_notes:for_player(PlayerId)
        end,
    Limit = to_integer(maps:get(~"limit", Params, ~"50"), 50),
    Offset = to_integer(maps:get(~"offset", Params, ~"0"), 0),
    Window = lists:sublist(lists:nthtail(min(Offset, length(All)), All), Limit),
    {ok, #{
        data => Window,
        page => #{limit => Limit, offset => Offset, total => length(All)}
    }}.

%% `Ctx` carries the actor that was admitted, so the note records who wrote it
%% without a second lookup and without trusting a display name from the body.
-spec add(map(), asobi_ops_extension:ctx()) -> asobi_rpc:reply().
add(#{~"player_id" := PlayerId, ~"body" := Body}, #{actor := #{display := Author}}) when
    Body =/= ~""
->
    {ok, Note} = asobi_notes:add(PlayerId, Body, Author),
    {ok, #{note => Note}};
add(_Params, _Ctx) ->
    {error, ~"notes.empty"}.

to_integer(Value, Default) ->
    try
        binary_to_integer(Value)
    catch
        _:_ -> Default
    end.
