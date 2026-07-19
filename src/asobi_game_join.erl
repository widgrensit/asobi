-module(asobi_game_join).
-moduledoc """
Dispatch to a game module's join callback, preferring the context-carrying
`join/3` when the module exports it.

Shared by `asobi_match_server` and `asobi_world_server` so the two cannot
drift on which arity wins.
""".

-export([invoke/4]).

-doc """
Call `Mod:join/3` if exported, otherwise `Mod:join/2`.

The export check runs per join rather than being cached at init: a module
can gain or lose `join/3` across a hot code upgrade, and a cached decision
would keep calling the arity that no longer exists.
""".
-spec invoke(module(), binary(), map(), term()) ->
    {ok, term()} | {error, term()}.
invoke(Mod, PlayerId, Ctx, GameState) when is_map(Ctx) ->
    case erlang:function_exported(Mod, join, 3) of
        true -> Mod:join(PlayerId, Ctx, GameState);
        false -> Mod:join(PlayerId, GameState)
    end.
