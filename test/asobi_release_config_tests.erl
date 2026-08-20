-module(asobi_release_config_tests).
-include_lib("eunit/include/eunit.hrl").

%% asobi#529: relx's extended start script substitutes every `${...}` form in a
%% `.src` release file, comments included, and its awk loop spins at 100% CPU
%% forever on a name it cannot resolve. A gateway image shipped that way looks
%% Running, logs nothing and never boots, so the trap is invisible by design -
%% which is why it is worth a test rather than a code-review habit.
placeholders_are_resolvable_names_test_() ->
    [
        {File, fun() -> ?assertEqual([], bad_placeholders(File)) end}
     || File <- filelib:wildcard("config/*.src")
    ].

bad_placeholders(File) ->
    {ok, Bin} = file:read_file(File),
    [Name || Name <- placeholders(Bin), not is_env_name(Name)].

placeholders(Bin) ->
    case re:run(Bin, "[$]{([^}]*)}", [global, {capture, [1], binary}]) of
        {match, Matches} -> [Name || [Name] <- Matches, is_binary(Name)];
        nomatch -> []
    end.

is_env_name(<<C, Rest/binary>>) when C =:= $_; C >= $A, C =< $Z; C >= $a, C =< $z ->
    is_env_name_tail(Rest);
is_env_name(_) ->
    false.

is_env_name_tail(<<>>) ->
    true;
is_env_name_tail(<<C, Rest/binary>>) when
    C =:= $_; C >= $0, C =< $9; C >= $A, C =< $Z; C >= $a, C =< $z
->
    is_env_name_tail(Rest);
is_env_name_tail(_) ->
    false.
