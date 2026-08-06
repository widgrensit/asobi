-module(asobi_console_routes_tests).

-include_lib("eunit/include/eunit.hrl").

%% Drift guard between the console and the route table it reads.
%%
%% The console is a separate toolchain, so nothing in the Erlang build knows
%% that a screen asks for `/api/v1/ops/leaderboards`. Rename or retire an ops
%% route and every Erlang test still passes while one console screen shows an
%% error banner that only a browser would ever see.
%%
%% This reads the paths `console/src/screens.jsx` asks for - the `path=` prop
%% of a list or detail screen and the argument to `useOps` - and holds them to
%% `asobi_ops_caps:classes/0`, which is the table the router is checked
%% against in turn.
%%
%% It is a text scan of a file in another language, so it fails closed twice:
%% a scan that finds too few paths is a broken scanner, and a file it cannot
%% read is a failure rather than an empty pass.

-define(SCREENS, "console/src/screens.jsx").
-define(MIN_PATHS, 12).

screens() ->
    case file:read_file(?SCREENS) of
        {ok, Source} -> Source;
        {error, Reason} -> erlang:error({?SCREENS, Reason})
    end.

%% `path={`/players/${encodeURIComponent(id)}`}` and `useOps('/features', ...)`
%% are the two call shapes. Template holes become `_`, which is how the
%% capability table spells a bound segment.
paths() ->
    Source = screens(),
    lists:usort([
        normalise(Path)
     || Pattern <- [~"path=", ~"useOps("],
        Path <- literals(Source, Pattern)
    ]).

literals(Source, Pattern) ->
    [
        Literal
     || Position <- binary:matches(Source, Pattern),
        Literal <- [literal_at(Source, Position, byte_size(Pattern))],
        Literal =/= none
    ].

literal_at(Source, {Start, _}, PatternSize) ->
    Rest = binary:part(Source, Start + PatternSize, byte_size(Source) - Start - PatternSize),
    opening(Rest).

opening(<<${, Rest/binary>>) -> opening(Rest);
opening(<<$', Rest/binary>>) -> until($', Rest);
opening(<<$", Rest/binary>>) -> until($", Rest);
opening(<<$`, Rest/binary>>) -> until($`, Rest);
opening(_Rest) -> none.

until(Quote, Rest) ->
    case binary:split(Rest, <<Quote>>) of
        [Literal, _] -> Literal;
        _ -> none
    end.

%% `${...}` is a bound segment, and nothing else in these paths is dynamic.
normalise(Path) ->
    iolist_to_binary(
        lists:join(~"/", [
            case binary:match(Segment, ~"${") of
                nomatch -> Segment;
                _ -> ~"_"
            end
         || Segment <- binary:split(Path, ~"/", [global])
        ])
    ).

%% The same table, as the paths a caller writes.
declared() ->
    lists:usort([
        iolist_to_binary([~"/", lists:join(~"/", [segment(S) || S <- Segments])])
     || {get, Segments, _Class} <- asobi_ops_caps:classes()
    ]).

segment('_') -> ~"_";
segment(Segment) -> Segment.

%%--------------------------------------------------------------------

the_scan_finds_the_paths_test() ->
    Paths = paths(),
    ?assert(length(Paths) >= ?MIN_PATHS, {too_few_paths, Paths}),
    ?assert(lists:member(~"/players", Paths)),
    ?assert(lists:member(~"/players/_", Paths)),
    ?assert(lists:member(~"/leaderboards/_/entries", Paths)),
    ?assert(lists:member(~"/features", Paths)).

every_path_the_console_asks_for_is_a_declared_ops_route_test() ->
    ?assertEqual([], paths() -- declared()).

%% Not the reverse assertion - the console is allowed to leave a route
%% unrendered - but it is worth seeing which ones it does not use.
%%
%% `/players/_/export` is here because the console has no screen for it yet.
%% The erasure route is absent from this list for a different reason: it is a
%% POST, and `declared/0` only reads the `get` half of the table.
unused_ops_routes_are_visible_test() ->
    Unused = declared() -- paths(),
    ?assertEqual([~"/economy/listings/_", ~"/players/_/export"], Unused).
