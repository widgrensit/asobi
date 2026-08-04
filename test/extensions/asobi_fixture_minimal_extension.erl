-module(asobi_fixture_minimal_extension).
-moduledoc """
The smallest legal manifest: `info/0` and nothing else.

Exists to prove the optional callbacks really are optional, and that an
extension nobody can call is a warning rather than a boot failure.
""".
-behaviour(asobi_extension).

-export([info/0]).

-spec info() -> asobi_extension:info().
info() ->
    #{name => minimal, extension_version => 1}.
