-module(asobi_auth_error).

%% Shared normalization of a registration/upgrade changeset failure into the
%% stable auth error contract, so the register and guest-upgrade paths don't
%% each string-match kura changeset internals: a duplicate username is a 409
%% conflict with a stable atom, anything else is a 422 validation failure with
%% per-field detail for form UIs. (asobi_auth_controller:register/1 should adopt
%% this once its 409 branch lands - see the register-409 change.)

-export([from_changeset_fields/1, username_taken/1, provider_uid_taken/1]).
-export([validation_failed/1, registration_denied/1]).

%% kura's default message for a unique-index violation.
-define(UNIQUE_MSG, ~"has already been taken").

-spec from_changeset_fields(map()) ->
    {json, integer(), map(), map()} | {asobi_error, asobi_error:code()}.
from_changeset_fields(#{username := Msgs} = Fields) when is_list(Msgs) ->
    case lists:member(?UNIQUE_MSG, Msgs) of
        true -> {asobi_error, ~"auth.username_taken"};
        false -> validation_failed(Fields)
    end;
from_changeset_fields(Fields) ->
    validation_failed(Fields).

%% `asobi_registration:check/1` reports a deny as a string. Map it to a code
%% with explicit clauses rather than passing it through: a reason is a
%% server-side label that may be reworded, and the catch-all means a future
%% one lands on a defined code instead of minting an undefined one.
-spec registration_denied(binary()) -> {asobi_error, asobi_error:code()}.
registration_denied(~"password_registration_disabled") ->
    {asobi_error, ~"auth.password_registration_disabled"};
registration_denied(_Reason) ->
    {asobi_error, ~"auth.registration_closed"}.

%% Whether a raw #kura_changeset.errors list is specifically a username
%% uniqueness conflict (the generated-username retry paths need to tell that
%% apart from any other error on the same field, e.g. a future format/length
%% validation, before consuming a retry). One place to know kura's message
%% shape, shared by the guest and OAuth create-player retry loops.
-spec username_taken([{atom(), binary()}]) -> boolean().
username_taken(Errors) ->
    lists:keyfind(username, 1, Errors) =:= {username, ?UNIQUE_MSG}.

%% Same distinction for the OAuth/guest identity race: was this insert
%% failure specifically the unique {provider, provider_uid} conflict (a
%% concurrent first-sign-in won), or something else (a provider claim over a
%% column limit, a transient DB error)? Only the former should read as a
%% retryable "already registering" - anything else is a real failure that
%% looks identical to the client unless this is checked.
-spec provider_uid_taken([{atom(), binary()}]) -> boolean().
provider_uid_taken(Errors) ->
    lists:keyfind(provider_uid, 1, Errors) =:= {provider_uid, ?UNIQUE_MSG}.

%% `fields` stays a top-level key (form UIs read it) and is the object's
%% `details` too - see asobi_error:legacy/2.
-spec validation_failed(map()) -> {json, pos_integer(), map(), map()}.
validation_failed(Fields) ->
    asobi_error:legacy(~"validation_failed", #{fields => Fields}).
