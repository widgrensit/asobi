-module(prop_lua_state_round_trip).
-include_lib("eunit/include/eunit.hrl").
-undef(LET).
-include_lib("proper/include/proper.hrl").

%% PropEr property: encoding any reasonable Erlang term into Luerl,
%% decoding it back, and walking the result through deep_decode/1
%% returns a value that round-trips a second pass without changing
%% shape. This catches encode/decode pathologies in
%% asobi_lua_api:deep_decode/1 — the canonical decoder used by every
%% bridge callback.

-define(NUMTESTS, 50).

prop_round_trip_test_() ->
    {timeout, 60,
        ?_assert(
            proper:quickcheck(prop_round_trip(), [
                {numtests, ?NUMTESTS}, {to_file, user}
            ])
        )}.

prop_round_trip() ->
    ?FORALL(
        Term,
        asobi_term(),
        round_trips(Term)
    ).

%% --- Generators: shapes the bridge actually sees ---

asobi_term() ->
    proper_types:oneof([
        asobi_scalar(),
        asobi_map_shallow(),
        asobi_map_nested(),
        asobi_list_shallow()
    ]).

asobi_scalar() ->
    proper_types:oneof([
        proper_types:integer(-1000, 1000),
        proper_types:float(),
        proper_types:boolean(),
        ascii_binary()
    ]).

ascii_binary() ->
    %% Restrict to printable ASCII so Luerl's UTF-8 handling doesn't
    %% mask a real bug. The bridge does receive arbitrary bytes from
    %% clients in production, but we test that path elsewhere.
    ?LET(
        Cs,
        proper_types:list(proper_types:integer(32, 126)),
        list_to_binary(Cs)
    ).

asobi_map_shallow() ->
    ?LET(
        Pairs,
        proper_types:list({ascii_binary_nonempty(), asobi_scalar()}),
        maps:from_list(Pairs)
    ).

asobi_map_nested() ->
    ?LET(
        Pairs,
        proper_types:list({ascii_binary_nonempty(), asobi_map_shallow()}),
        maps:from_list(Pairs)
    ).

asobi_list_shallow() ->
    proper_types:list(asobi_scalar()).

ascii_binary_nonempty() ->
    ?LET(
        B,
        ascii_binary(),
        case B of
            <<>> -> ~"k";
            _ -> B
        end
    ).

%% --- Property body ---

-spec round_trips(term()) -> boolean().
round_trips(Term) ->
    {ok, St} = asobi_lua_loader:new(fixture_path("test_match.lua")),
    {Enc, St1} = luerl:encode(Term, St),
    Decoded = asobi_lua_api:deep_decode(luerl:decode(Enc, St1)),
    {Enc2, St2} = luerl:encode(Decoded, St1),
    Decoded2 = asobi_lua_api:deep_decode(luerl:decode(Enc2, St2)),
    Decoded =:= Decoded2.

%% --- Helpers ---

fixture_path(Name) ->
    case code:lib_dir(asobi) of
        {error, _} -> error(asobi_not_loaded);
        Dir -> filename:join([Dir, "test", "fixtures", "lua", Name])
    end.
