-module(asobi_storage_tests).

-include_lib("eunit/include/eunit.hrl").

%% The release-level off switch. Storage is on by default - the opposite of the
%% console - so an absent env means enabled, and only `false` closes it.

switch_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun on_by_default/0,
        fun false_turns_it_off/0,
        fun true_keeps_it_on/0
    ]}.

setup() ->
    Was = application:get_env(asobi, storage),
    application:unset_env(asobi, storage),
    Was.

cleanup(Was) ->
    case Was of
        {ok, Value} -> application:set_env(asobi, storage, Value);
        undefined -> application:unset_env(asobi, storage)
    end.

on_by_default() ->
    ?assert(asobi_storage:enabled()).

false_turns_it_off() ->
    application:set_env(asobi, storage, false),
    ?assertNot(asobi_storage:enabled()).

true_keeps_it_on() ->
    application:set_env(asobi, storage, true),
    ?assert(asobi_storage:enabled()).
