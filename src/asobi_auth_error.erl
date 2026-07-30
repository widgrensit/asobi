-module(asobi_auth_error).

%% Shared normalization of a registration/upgrade changeset failure into the
%% stable auth error contract, so the register and guest-upgrade paths don't
%% each string-match kura changeset internals: a duplicate username is a 409
%% conflict with a stable atom, anything else is a 422 validation failure with
%% per-field detail for form UIs. (asobi_auth_controller:register/1 should adopt
%% this once its 409 branch lands - see the register-409 change.)

-export([from_changeset_fields/1, username_taken/1]).

%% kura's default message for a unique-index violation.
-define(UNIQUE_MSG, ~"has already been taken").

-spec from_changeset_fields(map()) -> {json, integer(), map(), map()}.
from_changeset_fields(#{username := Msgs} = Fields) when is_list(Msgs) ->
    case lists:member(?UNIQUE_MSG, Msgs) of
        true -> {json, 409, #{}, #{error => ~"username_taken"}};
        false -> validation_failed(Fields)
    end;
from_changeset_fields(Fields) ->
    validation_failed(Fields).

%% Whether a raw #kura_changeset.errors list is specifically a username
%% uniqueness conflict (the generated-username retry paths need to tell that
%% apart from any other error on the same field, e.g. a future format/length
%% validation, before consuming a retry). One place to know kura's message
%% shape, shared by the guest and OAuth create-player retry loops.
-spec username_taken([{atom(), binary()}]) -> boolean().
username_taken(Errors) ->
    lists:keyfind(username, 1, Errors) =:= {username, ?UNIQUE_MSG}.

-spec validation_failed(map()) -> {json, 422, map(), map()}.
validation_failed(Fields) ->
    {json, 422, #{}, #{error => ~"validation_failed", fields => Fields}}.
