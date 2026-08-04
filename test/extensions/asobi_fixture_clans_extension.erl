-module(asobi_fixture_clans_extension).
-moduledoc "A second extension, whose application depends on the first, so ordering is observable.".
-behaviour(asobi_extension).

-export([info/0, rpc/0, lua/0, sup/0, owns/0]).

-spec info() -> asobi_extension:info().
info() ->
    #{name => clans, extension_version => 2}.

-spec rpc() -> asobi_extension:rpc().
rpc() ->
    #{~"clans.create" => {asobi_fixture_clans_rpc, create, 2}}.

-spec lua() -> asobi_extension:lua().
lua() ->
    #{
        ~"clans" => #{
            ~"of" => #{
                mfa => {asobi_fixture_clans_lua, of_player, 1},
                args => [binary],
                effects => none,
                vms => [match, world, zone, bot]
            }
        }
    }.

-spec sup() -> [supervisor:child_spec()].
sup() ->
    [
        #{
            id => roster,
            start => {asobi_fixture_worker, start_link, [asobi_fixture_clans_worker]}
        }
    ].

-spec owns() -> asobi_extension:owns().
owns() ->
    #{
        tables => [~"clans"],
        rpc => [~"clans"],
        lua => [~"clans"],
        queues => [~"clans"]
    }.
