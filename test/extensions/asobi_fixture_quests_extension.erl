-module(asobi_fixture_quests_extension).
-moduledoc "A complete extension manifest, shaped exactly like the design's worked example.".
-behaviour(asobi_extension).

-export([info/0, rpc/0, lua/0, sup/0, owns/0]).

-spec info() -> asobi_extension:info().
info() ->
    #{name => quests, extension_version => 1}.

-spec rpc() -> asobi_extension:rpc().
rpc() ->
    #{
        ~"quests.list" => {asobi_fixture_quests_rpc, list, 2},
        ~"quests.claim" => {asobi_fixture_quests_rpc, claim, 2}
    }.

-spec lua() -> asobi_extension:lua().
lua() ->
    #{
        ~"quests" => #{
            ~"progress" => #{
                mfa => {asobi_fixture_quests_lua, progress, 2},
                args => [binary, integer],
                effects => write,
                vms => [match, world]
            },
            ~"status" => #{
                mfa => {asobi_fixture_quests_lua, status, 2},
                args => [binary],
                effects => none,
                vms => [match, world, bot]
            }
        }
    }.

-spec sup() -> [supervisor:child_spec()].
sup() ->
    [
        #{
            id => tracker,
            start => {asobi_fixture_worker, start_link, [asobi_fixture_quests_worker]}
        }
    ].

-spec owns() -> asobi_extension:owns().
owns() ->
    #{
        tables => [~"quests", ~"quest_progress"],
        rpc => [~"quests"],
        lua => [~"quests"],
        queues => [~"quests"]
    }.
