-module(asobi_dgram_env).
-moduledoc """
Folds the datagram plane's environment variables into the application env.

Every other way of configuring asobi ends up as an Erlang term in `sys.config`,
and that is not reachable from the published image: a self-hoster runs
`ghcr.io/widgrensit/asobi` and configures it with environment variables. Without
this module the whole datagram plane is unreachable by exactly the audience it
was built for, which is the sort of gap that makes a feature technically present
and practically absent.

Applied at boot, **before** the supervisor reads `role`, because the role decides
which tree starts at all.

## The application env wins

A value already set in `sys.config` is never overwritten. A deployment that
configures asobi in Erlang keeps doing so, and a container deployment gets the
same surface through variables. Nothing has two sources of truth at once.

## The secret prefers a file

`ASOBI_DGRAM_LINK_SECRET_FILE` beats `ASOBI_DGRAM_LINK_SECRET`, matching how the
ops secret is handled and for the same reason: a file stays out of
`docker inspect` and out of the process environment. An unreadable file is an
error rather than a silent fallback - a deployment that mounted a secret and got
the path wrong must not come up quietly with no authentication on its link.
""".

-include_lib("kernel/include/logger.hrl").

-export([apply/0]).

-doc "Reads the environment into the application env. Idempotent.".
-spec apply() -> ok.
apply() ->
    set_role(),
    set_gateway_config(),
    set_link_secret(),
    set_engine_link(),
    set_endpoint(),
    set_pose(),
    ok.

%% --- Internal ---

%% Anything but `dgram_gw` is the engine, including a typo. Defaulting a
%% misspelling to the engine keeps a deployment serving its game; defaulting it
%% to the gateway would silently take the game down.
set_role() ->
    case {application:get_env(asobi, role), os:getenv("ASOBI_ROLE")} of
        {undefined, "dgram_gw"} -> application:set_env(asobi, role, dgram_gw);
        _ -> ok
    end.

set_gateway_config() ->
    case application:get_env(asobi, dgram) of
        {ok, _} ->
            ok;
        undefined ->
            Config = put_int(
                shards,
                "ASOBI_DGRAM_SHARDS",
                put_int(
                    link_port,
                    "ASOBI_DGRAM_LINK_PORT",
                    put_int(port, "ASOBI_DGRAM_PORT", #{})
                )
            ),
            case map_size(Config) of
                0 -> ok;
                _ -> application:set_env(asobi, dgram, Config)
            end
    end.

set_link_secret() ->
    case application:get_env(asobi, dgram_link_secret) of
        {ok, _} ->
            ok;
        undefined ->
            case os:getenv("ASOBI_DGRAM_LINK_SECRET_FILE") of
                False when False =:= false; False =:= "" ->
                    set_binary(dgram_link_secret, "ASOBI_DGRAM_LINK_SECRET");
                Path ->
                    read_secret_file(Path)
            end
    end.

read_secret_file(Path) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            case string:trim(Contents) of
                ~"" ->
                    ?LOG_ERROR(#{
                        msg => ~"dgram_link_secret_file_empty", path => list_to_binary(Path)
                    });
                Secret ->
                    application:set_env(asobi, dgram_link_secret, Secret)
            end,
            ok;
        {error, Reason} ->
            ?LOG_ERROR(#{
                msg => ~"dgram_link_secret_file_unreadable",
                path => list_to_binary(Path),
                reason => Reason
            }),
            ok
    end.

%% `host:port`, which is what a compose file has to hand. Configuring this is the
%% engine's opt-in: without it nothing is dialled and no client can mint.
set_engine_link() ->
    case {application:get_env(asobi, dgram_gateway), os:getenv("ASOBI_DGRAM_GATEWAY")} of
        {undefined, Value} when is_list(Value), Value =/= "" ->
            case host_port(Value) of
                {ok, Host, Port} ->
                    application:set_env(asobi, dgram_gateway, #{host => Host, port => Port});
                error ->
                    ?LOG_ERROR(#{
                        msg => ~"dgram_gateway_malformed",
                        detail => ~"expected host:port",
                        value => list_to_binary(Value)
                    })
            end;
        _ ->
            ok
    end.

set_endpoint() ->
    case application:get_env(asobi, dgram_endpoint) of
        {ok, _} -> ok;
        undefined -> set_binary(dgram_endpoint, "ASOBI_DGRAM_ENDPOINT")
    end.

%% `x:100,y:100,vx:100,vy:100` - name and scale, in canonical order. Terse
%% because it is a compose file, and order-bearing because the wire is a fixed
%% layout: reordering this changes what every field on the wire means.
set_pose() ->
    case {application:get_env(asobi, dgram_pose), os:getenv("ASOBI_DGRAM_POSE_FIELDS")} of
        {undefined, Value} when is_list(Value), Value =/= "" ->
            case parse_fields(binary:split(list_to_binary(Value), ~",", [global]), []) of
                {ok, Fields} ->
                    Pose = #{fields => Fields},
                    application:set_env(asobi, dgram_pose, with_period(Pose));
                error ->
                    ?LOG_ERROR(#{
                        msg => ~"dgram_pose_fields_malformed",
                        detail => ~"expected name:scale,name:scale",
                        value => list_to_binary(Value)
                    })
            end;
        _ ->
            ok
    end.

with_period(Pose) ->
    case int_env("ASOBI_DGRAM_POSE_PERIOD") of
        {ok, P} -> Pose#{period_ticks => P};
        error -> Pose
    end.

%% Parsed in binaries rather than through the `string` module, whose every
%% function types as chardata() even when handed a plain string. Binaries keep
%% the types honest end to end and are what these values are stored as anyway.
parse_fields([], Acc) ->
    {ok, Acc};
parse_fields([Spec | Rest], Acc) ->
    case binary:split(trim(Spec), ~":", [global]) of
        [Name, ScaleBin] when Name =/= ~"" ->
            case to_int(ScaleBin) of
                {ok, Scale} when Scale > 0 ->
                    %% Appended rather than consed-and-reversed: the list is
                    %% capped at eight fields, and lists:reverse/1's overlay
                    %% erases the element type.
                    parse_fields(Rest, Acc ++ [#{name => Name, scale => Scale}]);
                _ ->
                    error
            end;
        _ ->
            error
    end.

%% Splits on the LAST colon, so an address is read the way a reader would.
host_port(Value) ->
    Bin = trim(list_to_binary(Value)),
    case binary:matches(Bin, ~":") of
        [] ->
            error;
        Matches ->
            At = last_match(Matches),
            Host = binary:part(Bin, 0, At),
            Port = binary:part(Bin, At + 1, byte_size(Bin) - At - 1),
            case {Host, to_int(Port)} of
                {~"", _} -> error;
                {_, {ok, N}} when N > 0, N =< 65535 -> {ok, binary_to_list(Host), N};
                _ -> error
            end
    end.

%% Only keys that were actually set land in the map, so an unset variable leaves
%% the built-in default in place rather than overwriting it with something.
put_int(Key, Var, Map) ->
    case int_env(Var) of
        {ok, N} -> Map#{Key => N};
        error -> Map
    end.

%% Written out rather than via lists:last/1, whose overlay erases the element
%% type and leaves the offset untypeable.
-spec last_match([{non_neg_integer(), non_neg_integer()}]) -> non_neg_integer().
last_match([{At, _}]) -> At;
last_match([_ | Rest]) -> last_match(Rest).

int_env(Var) ->
    case os:getenv(Var) of
        False when False =:= false; False =:= "" -> error;
        Value -> to_int(list_to_binary(Value))
    end.

-spec to_int(binary()) -> {ok, integer()} | error.
to_int(Bin) ->
    try
        {ok, binary_to_integer(trim(Bin))}
    catch
        _:_ -> error
    end.

%% Leading and trailing ASCII whitespace, written out because `string:trim/1`
%% types as chardata() and a compose file's values are worth being forgiving of.
-spec trim(binary()) -> binary().
trim(Bin) -> trim_trailing(trim_leading(Bin)).

trim_leading(<<C:8, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    trim_leading(Rest);
trim_leading(Bin) ->
    Bin.

trim_trailing(<<>>) ->
    <<>>;
trim_trailing(Bin) ->
    case binary:last(Bin) of
        C when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
            trim_trailing(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ ->
            Bin
    end.

set_binary(Key, Var) ->
    case os:getenv(Var) of
        False when False =:= false; False =:= "" -> ok;
        Value -> application:set_env(asobi, Key, list_to_binary(Value))
    end.
