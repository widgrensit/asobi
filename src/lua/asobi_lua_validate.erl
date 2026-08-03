-module(asobi_lua_validate).
-moduledoc """
Validates a Lua file against the asobi_lua loader without starting the
runtime — load it through `asobi_lua_loader:new/1` so syntax errors,
sandbox violations, and `require/1` traversal attempts surface as a
non-zero exit. Designed for CI use.

## Usage

In a CI step running against the asobi_lua release image:

```bash
docker run --rm -v $(pwd)/lua:/g ghcr.io/widgrensit/asobi_lua \
  bin/asobi_lua eval 'asobi_lua_validate:cli(["/g/match.lua"]).'
```

Exits 0 if the script loads clean, 1 with the loader's error reason
on stderr otherwise. Multiple paths can be passed; they are validated
sequentially and the script exits on the first failure.
""".

-export([validate/1, cli/1]).

-spec validate(file:filename_all()) -> ok | {error, term()}.
validate(Path) ->
    case asobi_lua_loader:new(Path) of
        {ok, _LuaSt} -> ok;
        {error, _} = Err -> Err
    end.

-spec cli([string() | binary()]) -> no_return().
cli([]) ->
    io:format(standard_error, "usage: asobi_lua_validate:cli([\"file.lua\", ...]).~n", []),
    halt(2);
cli(Paths) when is_list(Paths) ->
    cli_loop(Paths).

cli_loop([]) ->
    halt(0);
cli_loop([Path | Rest]) ->
    case validate(Path) of
        ok ->
            io:format("ok ~ts~n", [to_iolist(Path)]),
            cli_loop(Rest);
        {error, Reason} ->
            io:format(
                standard_error,
                "fail ~ts ~p~n",
                [to_iolist(Path), Reason]
            ),
            halt(1)
    end.

to_iolist(P) when is_binary(P) -> P;
to_iolist(P) when is_list(P) -> P.
