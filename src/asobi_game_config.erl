-module(asobi_game_config).
-moduledoc """
The core-owned write path for game config a loader declares.

A loader - the Lua bundle loader in `asobi_lua_config`, or anything else that
reads a game's own declaration - hands the whole config term to
`apply_config/1` and never writes asobi's application environment itself. This
module decides what the effective registry ends up looking like, and in which
order the keys are written.

## Two mode layers, one merge

Game modes come from two independent sources, kept in two application-env keys
so neither source can clobber the other:

1. `game_modes` - the **operator** layer, declared in `sys.config`. asobi
   never writes this key.
2. `script_game_modes` - the **script** layer, the complete set of modes the
   currently loaded game declares. `apply_config/1` replaces that set
   wholesale, so a mode deleted from `config.lua` is gone after the next load
   instead of surviving forever.

`modes/0` composes the two in that order: the script layer first, the operator
layer on top. An operator mode therefore wins a name clash, and no bundle
reload can redefine or drop it. Every reader goes through `modes/0`.

## guest_auth is replaced, not merged

`guest_auth` is the game's half of ADR 0004's two-key AND (the operator owns
the pepper), so a declared value simply replaces the current flag. It is
written before the modes so a reader waking on the mode change already sees
the final auth posture.

A term that omits a key leaves that key alone: `apply_config(#{modes => M})` is
how the config watcher refreshes mode shape without letting a bundle write flip
auth posture at runtime.
""".

-include_lib("kernel/include/logger.hrl").

-export([apply_config/1, modes/0]).

-type modes() :: #{binary() => map() | module()}.
-type config() :: #{modes => modes(), guest_auth => boolean()}.

-export_type([config/0, modes/0]).

-doc "The effective game modes: the script layer with the operator layer on top.".
-spec modes() -> modes().
modes() ->
    maps:merge(env_modes(script_game_modes), env_modes(game_modes)).

-doc "Apply a declared game config. The only supported writer of these keys.".
-spec apply_config(config()) -> ok.
apply_config(Config) ->
    ok = write_guest_auth(Config),
    write_modes(Config).

-spec write_guest_auth(config()) -> ok.
write_guest_auth(#{guest_auth := Declared}) when is_boolean(Declared) ->
    application:set_env(asobi, guest_auth, Declared);
write_guest_auth(_) ->
    ok.

-spec write_modes(config()) -> ok.
write_modes(#{modes := Declared}) when is_map(Declared) ->
    application:set_env(asobi, script_game_modes, Declared),
    ?LOG_NOTICE(#{
        msg => ~"game config applied",
        declared => maps:keys(Declared),
        effective => maps:keys(modes())
    }),
    ok;
write_modes(_) ->
    ok.

-spec env_modes(atom()) -> modes().
env_modes(Key) ->
    case application:get_env(asobi, Key, #{}) of
        Modes when is_map(Modes) -> Modes;
        _ -> #{}
    end.
