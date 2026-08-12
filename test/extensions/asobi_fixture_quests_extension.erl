-module(asobi_fixture_quests_extension).
-moduledoc "A complete extension manifest, shaped exactly like the design's worked example.".
-behaviour(asobi_extension).

-export([info/0, rpc/0, lua/0, sup/0, owns/0, codes/0, ops/0, erase_player/1, export_player/1]).

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
                mfa => {asobi_fixture_quests_lua, status, 1},
                args => [binary],
                effects => none,
                vms => [match, world]
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

-spec codes() -> asobi_extension:codes().
codes() ->
    #{
        ~"quests.already_claimed" => #{
            status => 409, message => ~"This quest was already claimed."
        },
        ~"quests.not_found" => #{status => 404, message => ~"No quest exists with this id."}
    }.

-spec owns() -> asobi_extension:owns().
owns() ->
    #{
        tables => [~"quests", ~"quest_progress"],
        rpc => [~"quests"],
        lua => [~"quests"],
        queues => [~"quests"]
    }.

-spec ops() -> asobi_extension:ops().
ops() ->
    #{
        ~"define" => #{
            method => post,
            mfa => {asobi_fixture_quests_ops, define, 2},
            class => config
        },
        ~"summary" => #{
            method => get,
            mfa => {asobi_fixture_quests_ops, summary, 2},
            class => read
        }
    }.

-spec erase_player(binary()) -> ok | {error, term()}.
erase_player(PlayerId) ->
    asobi_fixture_erase:run(quests, PlayerId).

-spec export_player(binary()) -> {ok, #{binary() => term()}} | {error, term()}.
export_player(PlayerId) ->
    asobi_fixture_export:run(quests, PlayerId).
