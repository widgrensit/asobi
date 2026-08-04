-module(asobi_test_helpers).

-export([start/1, unique_username/1]).
-export([http_routes/1, routes_missing_options/1, preflight_targets/1, sample_path/1]).

-spec start(list()) -> list().
start(Config) ->
    nova_test:start(asobi) ++ Config.

-spec unique_username(binary()) -> binary().
unique_username(_Prefix) ->
    %% Use first 32 chars of a hex-encoded random value
    Bytes = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(Bytes, lowercase),
    binary:part(Hex, 0, 32).

%% --- Router enumeration ---
%%
%% Tests that assert a property of "every route group" derive the groups from
%% `asobi_router:routes/1` through these, so a group added later is covered
%% without editing the test. Pure over the group list, so a suite can feed a
%% synthetic group and check the property actually fails on a bad one.

-spec http_routes([map()]) -> [{binary(), binary(), fun(), [atom()]}].
http_routes(Groups) ->
    [
        {Prefix, Path, Handler, maps:get(methods, Opts)}
     || #{prefix := Prefix, routes := Routes} <- Groups,
        {Path, Handler, Opts} <- Routes,
        is_map_key(methods, Opts)
    ].

-spec routes_missing_options([map()]) -> [{binary(), binary()}].
routes_missing_options(Groups) ->
    [
        {Prefix, Path}
     || {Prefix, Path, _Handler, Methods} <- http_routes(Groups),
        not lists:member(options, Methods)
    ].

%% One concrete request path per group that serves HTTP. Groups that only
%% carry a protocol handler (the WebSocket group) have no preflight to make.
-spec preflight_targets([map()]) -> [{binary(), binary()}].
preflight_targets(Groups) ->
    lists:flatmap(fun first_http_route/1, Groups).

-spec first_http_route(map()) -> [{binary(), binary()}].
first_http_route(#{prefix := Prefix} = Group) ->
    case http_routes([Group]) of
        [{_, Path, _, _} | _] -> [{Prefix, <<Prefix/binary, (sample_path(Path))/binary>>}];
        [] -> []
    end.

%% Concrete path for a declared route: every `:binding` segment becomes a
%% value no literal sibling route uses.
-spec sample_path(binary()) -> binary().
sample_path(Path) ->
    Segments = [
        case Segment of
            <<":", _/binary>> -> ~"g-1";
            Literal -> Literal
        end
     || Segment <- binary:split(Path, ~"/", [global])
    ],
    iolist_to_binary(lists:join(~"/", Segments)).
