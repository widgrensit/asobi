-module(asobi_fixture_clans_extension).
-moduledoc """
A second extension, whose application depends on the first, so ordering is
observable, and whose `requires/0` names the first, so the requires
provider-before-requirer rule is observable on the same install.
""".
-behaviour(asobi_extension).

-export([info/0, requires/0, rpc/0, lua/0, sup/0, owns/0, erase_player/1, export_player/1]).

-spec info() -> asobi_extension:info().
info() ->
    #{name => clans, extension_version => 2}.

%% Depends on the quests extension by name. Satisfied when clans's application
%% also depends on quests's (quests then resolves first); an out-of-order
%% problem when it does not.
-spec requires() -> [asobi_extension:name()].
requires() ->
    [quests].

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
                vms => [match, world, zone]
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

-spec erase_player(binary()) -> ok | {error, term()}.
erase_player(PlayerId) ->
    asobi_fixture_erase:run(clans, PlayerId).

-spec export_player(binary()) -> {ok, #{binary() => term()}} | {error, term()}.
export_player(PlayerId) ->
    asobi_fixture_export:run(clans, PlayerId).
