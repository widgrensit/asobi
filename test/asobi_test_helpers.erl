-module(asobi_test_helpers).

-export([start/1, unique_username/1, unique_id/1, binary_join/2]).
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

-doc """
A value no other run will produce, for any column under a unique index.

The local database persists between runs while CI gets a fresh one, so a
suite that writes a uniquely-constrained fixture and does not delete it only
ever breaks local developers - and looks like a regression in unrelated work
when it does (asobi#357).

`erlang:unique_integer/1` is not a substitute: it is unique within one
runtime instance, and each `rebar3 ct` run is a new one, so two runs hand out
the same low integers. Random bytes are unique across runs and let a suite
run concurrently with itself.
""".
-spec unique_id(binary()) -> binary().
unique_id(Prefix) ->
    Hex = binary:encode_hex(crypto:strong_rand_bytes(8), lowercase),
    <<Prefix/binary, "_", Hex/binary>>.

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
    [Target || Group <- Groups, Target <- first_http_route(Group)].

-doc "Join binaries with a separator. lists:join/2 widens to [term()], which then defeats iolist_to_binary/1 - see docs/eqwalizer-idioms.md.".
-spec binary_join(binary(), [binary()]) -> binary().
binary_join(_Sep, []) -> ~"";
binary_join(_Sep, [B]) -> B;
binary_join(Sep, [B | Rest]) -> <<B/binary, Sep/binary, (binary_join(Sep, Rest))/binary>>.

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
    binary_join(~"/", Segments).
