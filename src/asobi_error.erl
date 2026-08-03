-module(asobi_error).
-moduledoc """
The one error object.

Every failure asobi reports - REST, WebSocket, and the ops/RPC surfaces
built on top of them - is describable as:

```json
{"error": {"code": "storage.not_found", "message": "...", "details": {}}}
```

`code` is the contract. It is machine-readable, namespaced by domain
(`storage.`, `match.`, `world.`, `chat.`, `matchmaker.`) or bare when it is
cross-cutting (`rate_limited`, `internal`), and drawn from the closed set in
`codes/0` - a client may branch on it. `message` is prose for a human reading
a log; it may be reworded at any time and must not be parsed. `details` is
**always** a map, `#{}` when there is nothing to add, so no client needs a
null branch.

The code set is closed on purpose: script- and client-supplied strings never
become codes. An unrecognised reason is reported under a known code with the
raw string in `details`.

Codes carry their HTTP status (`status/1`), so a REST controller states the
failure and never the number:

```erlang
{asobi_error, ~"storage.not_found"}
{asobi_error, ~"save.version_conflict", #{current_version => 4}}
```

`register_handler/0` installs `handle/3` as the Nova return handler for those
tuples.
""".

-include_lib("kernel/include/logger.hrl").

-export([object/1, object/2, object/3]).
-export([status/1, message/1, codes/0]).
-export([from_ws_reason/1, ws_reasons/0]).
-export([handle/3, register_handler/0]).

-type code() :: binary().
-type details() :: #{atom() | binary() => term()}.
-type object() :: #{error := #{code := code(), message := binary(), details := details()}}.

-export_type([code/0, details/0, object/0]).

-define(UNKNOWN_MESSAGE, ~"The server reported an error code it does not define.").

%% {Code, HttpStatus, Message}. The whole contract, in one place.
-define(CODES, [
    %% Cross-cutting.
    {~"internal", 500, ~"The server failed while handling the request."},
    {~"rate_limited", 429, ~"Too many requests. Slow down and retry."},
    {~"join_rate_limited", 429, ~"Too many join attempts. Slow down and retry."},
    {~"payload_too_large", 413, ~"The payload is larger than the server accepts."},
    {~"invalid_json", 400, ~"The body is not valid JSON."},
    {~"invalid_message", 400, ~"The message is missing a string `type` field."},
    {~"invalid_payload", 400, ~"The payload is not the shape this request expects."},
    {~"missing_field", 400, ~"The payload is missing a required field."},
    {~"unknown_type", 400, ~"No handler is registered for this message type."},
    {~"unauthenticated", 401, ~"The credentials are missing, expired, or invalid."},
    {~"forbidden", 403, ~"The caller may not perform this action."},

    %% Cloud saves.
    {~"save.not_found", 404, ~"No cloud save exists in this slot."},
    {~"save.too_large", 413, ~"The save data is larger than the per-slot limit."},
    {~"save.version_conflict", 409, ~"The slot was written by another client."},
    {~"save.slot_limit_reached", 409, ~"The player has no free cloud-save slots."},

    %% Generic storage.
    {~"storage.not_found", 404, ~"No object exists at this collection and key."},
    {~"storage.forbidden", 403, ~"The object's permissions do not allow this."},
    {~"storage.value_too_large", 413, ~"The value is larger than the per-object limit."},
    {~"storage.invalid_perm", 400, ~"read_perm and write_perm must be \"public\" or \"owner\"."},
    {~"storage.invalid_request", 400, ~"The body must be a JSON object."},
    {~"storage.conflict", 500, ~"The collection and key resolved to more than one object."},
    {~"storage.query_failed", 500, ~"The storage query failed."},

    %% Matches, worlds, chat, matchmaking.
    {~"match.not_found", 404, ~"No live match exists with this id."},
    {~"match.not_in_match", 409, ~"This connection is not joined to a match."},
    {~"world.not_found", 404, ~"No live world exists with this id."},
    {~"world.already_joined", 409, ~"This connection is already joined to a world."},
    {~"chat.invalid_channel_id", 400, ~"The channel id is not valid."},
    {~"chat.too_many_channels", 429, ~"This connection has joined too many channels."},
    {~"matchmaker.unknown_mode", 400, ~"No game mode is configured under this name."},
    {~"matchmaker.queue_full", 503, ~"The matchmaking queue is full."},

    %% Fallback for a WebSocket reason with no code of its own yet.
    {~"ws.request_failed", 400, ~"The request failed. See `details.reason`."}
]).

%% Legacy WebSocket `reason` string -> code. Every reason asobi itself emits
%% that has a first-class code appears here; anything else (including a
%% reason produced by game script code) falls back to `ws.request_failed`
%% with the raw reason in `details`.
-define(WS_REASONS, [
    {~"payload_too_large", ~"payload_too_large"},
    {~"invalid_json", ~"invalid_json"},
    {~"invalid_message", ~"invalid_message"},
    {~"invalid_payload", ~"invalid_payload"},
    {~"missing_field", ~"missing_field"},
    {~"rate_limited", ~"rate_limited"},
    {~"join_rate_limited", ~"join_rate_limited"},
    {~"unknown_type", ~"unknown_type"},
    {~"internal", ~"internal"},
    {~"internal_error", ~"internal"},
    {~"invalid_token", ~"unauthenticated"},
    {~"not_authorized", ~"forbidden"},
    {~"not_in_match", ~"match.not_in_match"},
    {~"match_not_found", ~"match.not_found"},
    {~"world_not_found", ~"world.not_found"},
    {~"already_in_world", ~"world.already_joined"},
    {~"invalid_channel_id", ~"chat.invalid_channel_id"},
    {~"too_many_channels", ~"chat.too_many_channels"},
    {~"unknown_mode", ~"matchmaker.unknown_mode"},
    {~"queue_full", ~"matchmaker.queue_full"}
]).

-doc "The error object for `Code`, with no details.".
-spec object(code()) -> object().
object(Code) ->
    object(Code, #{}).

-doc "The error object for `Code`, carrying `Details`.".
-spec object(code(), details()) -> object().
object(Code, Details) when is_binary(Code), is_map(Details) ->
    object(Code, message(Code), Details).

-doc """
The error object for `Code` with the message overridden.

For the rare failure whose registered message would hide the one fact the
caller needs. Prefer `object/2`: a per-call message is not part of the
contract and cannot be translated or reused.
""".
-spec object(code(), binary(), details()) -> object().
object(Code, Message, Details) when is_binary(Code), is_binary(Message), is_map(Details) ->
    #{error => #{code => Code, message => Message, details => Details}}.

-doc "The HTTP status for `Code`. An undefined code is a server bug: 500.".
-spec status(code()) -> pos_integer().
status(Code) when is_binary(Code) ->
    case entry(Code) of
        {_, Status, _} -> Status;
        false -> 500
    end.

-doc "The registered human-readable message for `Code`.".
-spec message(code()) -> binary().
message(Code) when is_binary(Code) ->
    case entry(Code) of
        {_, _, Message} -> Message;
        false -> ?UNKNOWN_MESSAGE
    end.

-doc "Every defined code. The client-facing contract, enumerated.".
-spec codes() -> [code()].
codes() ->
    [Code || {Code, _, _} <- ?CODES].

-doc """
The error object for a WebSocket `reason` string.

`reason` is the pre-existing WebSocket error dialect and stays on the wire
untouched; this maps it onto a code. A reason with no code of its own becomes
`ws.request_failed` with the raw reason in `details` - script-supplied strings
must not be able to mint codes.
""".
-spec from_ws_reason(atom() | binary()) -> object().
from_ws_reason(Reason) when is_atom(Reason) ->
    from_ws_reason(atom_to_binary(Reason, utf8));
from_ws_reason(Reason) when is_binary(Reason) ->
    case lists:keyfind(Reason, 1, ?WS_REASONS) of
        {_, Code} -> object(Code);
        false -> object(~"ws.request_failed", #{reason => Reason})
    end.

-doc "The WebSocket reason -> code mapping, as `{Reason, Code}` pairs.".
-spec ws_reasons() -> [{binary(), code()}].
ws_reasons() ->
    ?WS_REASONS.

-doc """
Nova return handler for `{asobi_error, ...}` controller results.

`{asobi_error, Code}` and `{asobi_error, Code, Details}` take their HTTP
status from the code. `{asobi_error, Status, Code, Details}` overrides it,
for the caller that must return a status the code does not imply.
""".
-spec handle(
    {asobi_error, code()}
    | {asobi_error, code(), details()}
    | {asobi_error, pos_integer(), code(), details()},
    fun(),
    cowboy_req:req()
) -> {ok, cowboy_req:req()}.
handle({asobi_error, Code}, Callback, Req) ->
    handle({asobi_error, Code, #{}}, Callback, Req);
handle({asobi_error, Code, Details}, Callback, Req) when is_map(Details) ->
    handle({asobi_error, status(Code), Code, Details}, Callback, Req);
handle({asobi_error, Status, Code, Details}, Callback, Req) when
    is_integer(Status), is_binary(Code), is_map(Details)
->
    log_undefined(Code),
    nova_basic_handler:handle_json({json, Status, #{}, object(Code, Details)}, Callback, Req).

-doc "Install `handle/3` as Nova's handler for `{asobi_error, ...}` results.".
-spec register_handler() -> ok.
register_handler() ->
    nova_handlers:register_handler(asobi_error, fun ?MODULE:handle/3),
    ok.

-spec entry(code()) -> {code(), pos_integer(), binary()} | false.
entry(Code) ->
    lists:keyfind(Code, 1, ?CODES).

%% A code outside ?CODES reached a client: the contract says clients may
%% branch on `code`, so an undefined one is a defect that must not stay
%% silent.
-spec log_undefined(code()) -> ok.
log_undefined(Code) ->
    case entry(Code) of
        false -> ?LOG_ERROR(#{event => undefined_error_code, code => Code});
        _ -> ok
    end.
