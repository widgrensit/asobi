-module(asobi_console_env).
-moduledoc """
Turns the console on from the environment, for deployments that run a release
rather than write a `sys.config`.

## Why this is Erlang and not `sys.config.src`

relx substitutes `${VAR}` into `sys.config` before the VM starts, which is fine
for a value that is always set and fatal for one that is not: an unset
`${ASOBI_CONSOLE}` renders `{console, }` and the node will not boot. The
existing keys get away with it only because the image declares `ENV` defaults
for every one of them, and asobi itself ships no image.

Reading the environment here instead means a missing variable is simply a
missing variable, the keys stay optional, and a self-hoster who does write a
`sys.config` is unaffected - an OS variable overrides it only when set.

## Precedence

`ASOBI_OPS_SECRET_FILE` beats `ASOBI_OPS_SECRET`. Reading a secret from a file
keeps it out of `docker inspect`, out of the process environment, and out of a
compose file that tends to end up in git, which is why Docker and Kubernetes
both hand secrets over as files.

The database password cannot work this way - it is substituted into
`sys.config` before any of this runs - so `ASOBI_DB_PASSWORD_FILE` is not a
thing, whatever the deployment guide used to imply.

## Enabled with nothing to sign in with

The console stays off and says so at error level. It does not stop the node:
the game is the product and the console is an accessory, so taking players
offline because an operator surface is misconfigured is the wrong trade. A
console that renders a sign-in nothing can pass is the worse failure, because
it looks like it works.

`ops_secret` is not the only credential that counts. A managed environment
configures none on purpose - the only thing its console accepts is a token
`console.asobi.dev` minted for someone it authenticated, verified against
`ops_token_secret` and `env_id` (`m:asobi_ops_token`). Either credential being
configured is enough; neither is what turns the console off.
""".

-export([apply/0]).

-include_lib("kernel/include/logger.hrl").

-spec apply() -> ok.
apply() ->
    ok = set_binary(console_label, "ASOBI_CONSOLE_LABEL"),
    ok = set_boolean(console_production, "ASOBI_CONSOLE_PRODUCTION"),
    ok = set_secret(),
    ok = set_boolean(console, "ASOBI_CONSOLE"),
    ok = resolve().

%% Asked for, with nothing that can sign in, is the only bad combination.
-spec resolve() -> ok.
resolve() ->
    case {application:get_env(asobi, console, false), credential_configured()} of
        {true, false} ->
            application:set_env(asobi, console, false),
            ?LOG_ERROR(#{
                msg => ~"console_disabled_without_credential",
                detail =>
                    ~"enabled but nothing could sign in - set ASOBI_OPS_SECRET_FILE (preferred) or ASOBI_OPS_SECRET, or provision ASOBI_OPS_TOKEN_SECRET and GAME_ID for the managed minted-token path",
                effect => ~"the console stays off; the node is unaffected"
            }),
            ok;
        {true, true} ->
            ?LOG_NOTICE(#{
                msg => ~"console_enabled",
                path => ~"/console",
                detail => ~"Shares the game port. Put it behind TLS and restrict who can reach it."
            }),
            ok;
        _ ->
            ok
    end.

%% A self-hoster configures `ops_secret`. A managed environment configures none
%% and accepts only minted tokens, so asking about the secret alone switched the
%% console off underneath the whole cloud handoff.
-spec credential_configured() -> boolean().
credential_configured() ->
    secret_configured() orelse asobi_ops_token:configured().

-spec secret_configured() -> boolean().
secret_configured() ->
    case application:get_env(asobi, ops_secret) of
        {ok, S} when is_binary(S), S =/= ~"" -> true;
        _ -> false
    end.

%% A file beats a plain variable, and an unreadable file is an error rather
%% than a silent fallback - a deployment that mounted a secret and got the path
%% wrong must not come up quietly using something else.
-spec set_secret() -> ok.
set_secret() ->
    case os:getenv("ASOBI_OPS_SECRET_FILE") of
        false ->
            set_binary(ops_secret, "ASOBI_OPS_SECRET");
        "" ->
            set_binary(ops_secret, "ASOBI_OPS_SECRET");
        Path ->
            case file:read_file(Path) of
                {ok, Contents} ->
                    case string:trim(Contents) of
                        ~"" ->
                            ?LOG_ERROR(#{
                                msg => ~"ops_secret_file_empty", path => list_to_binary(Path)
                            });
                        Secret ->
                            application:set_env(asobi, ops_secret, Secret)
                    end,
                    ok;
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        msg => ~"ops_secret_file_unreadable",
                        path => list_to_binary(Path),
                        reason => Reason
                    }),
                    ok
            end
    end.

-spec set_binary(atom(), string()) -> ok.
set_binary(Key, Var) ->
    case os:getenv(Var) of
        false -> ok;
        "" -> ok;
        Value -> application:set_env(asobi, Key, list_to_binary(Value))
    end.

%% Only the words a person would write meaning yes. Anything else is false, so
%% a typo closes the surface rather than opening it.
-spec set_boolean(atom(), string()) -> ok.
set_boolean(Key, Var) ->
    case os:getenv(Var) of
        false ->
            ok;
        "" ->
            ok;
        Value ->
            application:set_env(asobi, Key, lists:member(string:lowercase(Value), truthy()))
    end.

-spec truthy() -> [string()].
truthy() -> ["1", "true", "yes", "on"].
