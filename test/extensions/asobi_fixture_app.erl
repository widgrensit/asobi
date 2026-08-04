-module(asobi_fixture_app).
-moduledoc """
Installs a fixture extension as a real, loaded OTP application.

`application:load/1` takes an application spec directly, so a fixture needs no
`.app` file on disk and no separate build. The manifest module is an ordinary
test module: discovery matches on the application's `modules` key, which is
exactly how it works for a real dependency.
""".

-export([install/3, uninstall/1]).

-spec install(atom(), module() | none, [atom()]) -> ok | {error, term()}.
install(App, Module, ExtraDeps) ->
    Modules =
        case Module of
            none -> [];
            _ -> [Module]
        end,
    application:load(
        {application, App, [
            {description, "asobi extension fixture"},
            {vsn, "0.0.0"},
            {registered, []},
            {applications, [kernel, stdlib, asobi | ExtraDeps]},
            {modules, Modules},
            {env, []}
        ]}
    ).

-spec uninstall(atom()) -> ok.
uninstall(App) ->
    _ = application:unload(App),
    ok.
