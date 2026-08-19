-module(asobi_error).
-moduledoc """
The one error object.

Every failure asobi reports - REST, WebSocket, and the ops/RPC surfaces
built on top of them - is describable as:

```json
{"error": {"code": "storage.not_found", "message": "...", "details": {}}}
```

`code` is the contract. It is machine-readable, namespaced by domain
(`storage.`, `save.`, `auth.`, `social.`, `match.`, `world.`, `chat.`,
`matchmaker.` and the rest) or bare when it is cross-cutting (`rate_limited`,
`internal`), and drawn from the closed set in `codes/0` - a client may branch
on it. `message` is prose for a human reading a log; it may be reworded at any
time and must not be parsed. `details` is **always** a map, `#{}` when there is
nothing to add, so no client needs a null branch.

The code set is closed on purpose: script- and client-supplied strings never
become codes. An unrecognised reason is reported under a known code with the
raw string in `details`.

An installed extension widens the set by declaring `codes/0` in its manifest
(see `m:asobi_extension`). That set is read once, at
`asobi_extensions:resolve/0`, from validated manifests, so the set is still
closed per deployment: nothing reachable from a request can add to it. Core's
own codes are `core_codes/0`, which is what `m:asobi_extension_reserved`
derives core's reserved namespaces from - an extension may only mint codes in
a domain it owns.

Codes carry their HTTP status (`status/1`), so a REST controller states the
failure and never the number:

```erlang
{asobi_error, ~"storage.not_found"}
{asobi_error, ~"save.version_conflict", #{current_version => 4}}
```

`register_handler/0` installs `handle/3` as the Nova return handler for those
tuples.

A handful of routes answered with more than `error` before the object existed
(`fields`, `errors`, `retry_after`, `field`). Those keys stay exactly where
they were and are also the object's `details`, so an existing client keeps
working and a new one reads one place: see `legacy/2`.
""".

-include_lib("kernel/include/logger.hrl").

-export([object/1, object/2, object/3]).
-export([legacy/2, legacy_body/2]).
-export([status/1, message/1, codes/0, core_codes/0, defined/1]).
-export([from_ws_reason/1, from_ws_reason/2, ws_reasons/0]).
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
    {~"validation_failed", 422, ~"One or more fields are invalid. See `details`."},
    {~"length_required", 411, ~"The request must declare a Content-Length."},
    {~"client_gate_denied", 403, ~"The registration gate rejected this request."},
    {~"not_ready", 503, ~"The server is still starting. Retry shortly."},

    %% Extension RPC. `rpc` is a core code domain, so no extension may own the
    %% `rpc` prefix and mint codes that look like the dispatcher's own.
    {~"rpc.unknown_method", 404, ~"No installed extension serves this RPC method."},
    %% Not a failure. The WebSocket carries everything in every state, so a
    %% client that cannot mint stays on TCP and loses latency, nothing else.
    {~"datagram_unavailable", 503, ~"The datagram plane is not available. Stay on the WebSocket."},
    {~"rpc.invalid_cid", 400, ~"`cid` must be 1-64 printable ASCII characters."},
    {~"rpc.unsupported_protocol", 400, ~"This server does not speak that RPC protocol version."},
    {~"rpc.invalid_params", 400, ~"`params` must be a JSON object."},

    %% Extension event push. `asobi_extensions:emit/4` fails closed: an event
    %% whose name is malformed, whose domain the emitter does not own, whose data
    %% is not JSON-encodable, or whose encoded data is too large never reaches a
    %% player.
    {
        ~"event.invalid_name",
        400,
        ~"An event name must be `<domain>.<name>` in [A-Za-z0-9_-], up to 64 bytes."
    },
    {
        ~"event.unowned_domain",
        403,
        ~"The event's domain is not an RPC prefix this extension owns."
    },
    {~"event.invalid_data", 400, ~"The event data is not JSON-encodable."},
    {~"event.payload_too_large", 413, ~"The event data is larger than the server accepts."},

    %% Accounts, providers, guests.
    {~"auth.registration_closed", 403, ~"This deployment is not accepting new players."},
    {
        ~"auth.password_registration_disabled",
        403,
        ~"This deployment accepts provider sign-in only."
    },
    {~"auth.username_taken", 409, ~"That username already belongs to another player."},
    {~"auth.invalid_credentials", 401, ~"The username or password is wrong."},
    {~"auth.unsupported_provider", 401, ~"No identity provider is configured under this name."},
    {~"auth.provider_rejected", 401, ~"The identity provider rejected the token."},
    {~"auth.provider_already_linked", 409, ~"That provider account is linked to another player."},
    {~"auth.already_registering", 409, ~"A concurrent sign-in is already creating this player."},
    {~"auth.identity_not_found", 404, ~"No linked identity exists for this provider."},
    {~"auth.last_auth_method", 422, ~"Unlinking this provider would leave no way to sign in."},
    {~"auth.registration_failed", 500, ~"The player could not be created."},
    {~"auth.link_failed", 500, ~"The provider identity could not be linked."},
    {~"auth.token_issue_failed", 500, ~"The session tokens could not be issued."},
    {~"guest.disabled", 403, ~"Guest authentication is not enabled for this deployment."},
    {~"guest.invalid_device_id", 400, ~"The device id is missing or too long."},
    {~"guest.weak_device_secret", 400, ~"The device secret is not 32-128 base64-encoded bytes."},
    {~"guest.invalid_device_secret", 401, ~"The device secret does not match this device."},
    {~"guest.revoked", 401, ~"This device's guest credential has been revoked."},
    {~"guest.already_upgraded", 401, ~"This account was claimed. Sign in with its credentials."},
    {~"guest.rate_limited", 429, ~"Guests are being created too fast right now. Retry shortly."},
    {~"guest.capacity_reached", 503, ~"The deployment is not creating more guests right now."},
    {~"guest.unavailable", 503, ~"The deployment could not check guest capacity. Retry shortly."},
    {~"guest.device_already_registered", 409, ~"Another guest already registered this device."},
    {~"guest.not_unclaimed", 409, ~"Only an unclaimed guest account can be upgraded."},
    {~"guest.create_failed", 500, ~"The guest player could not be created."},
    {~"player.not_found", 404, ~"No player exists with this id."},
    {
        ~"player.confirmation_failed",
        403,
        ~"The password does not match this account. Nothing was deleted."
    },
    {
        ~"player.credentials_changed",
        409,
        ~"This account's credentials changed while the request was in flight. Retry."
    },
    {~"player.erase_failed", 500, ~"The account could not be erased. Nothing was deleted."},

    %% Sessions, worlds, matches, tickets.
    {~"world.player_limit_reached", 429, ~"This player already owns as many worlds as allowed."},
    {~"world.capacity_reached", 503, ~"The deployment is running as many worlds as allowed."},
    {~"world.create_failed", 400, ~"The world could not be created. See `details.reason`."},
    {~"matchmaker.ticket_not_found", 404, ~"No matchmaking ticket exists with this id."},
    {~"vote.not_found", 404, ~"No vote exists with this id."},

    %% Leaderboards, economy, inventory, purchases.
    {~"leaderboard.client_submit_disabled", 403, ~"This board does not accept client submissions."},
    {~"leaderboard.capacity_reached", 503, ~"This leaderboard holds as many entries as allowed."},
    {~"economy.insufficient_funds", 402, ~"The wallet does not hold enough of this currency."},
    {~"economy.listing_inactive", 400, ~"This store listing is not on sale."},
    {~"economy.purchase_failed", 500, ~"The purchase could not be completed."},
    {~"inventory.item_not_found", 404, ~"No inventory item exists with this id."},
    {~"inventory.insufficient_quantity", 400, ~"The item stack holds fewer than the amount asked."},
    {~"inventory.invalid_quantity", 400, ~"`quantity` must be a positive integer within the cap."},
    {~"iap.verification_failed", 422, ~"The store rejected the receipt. See `details.reason`."},
    {~"iap.missing_transaction_id", 422, ~"The verified receipt carries no transaction id."},
    {~"iap.transaction_already_claimed", 409, ~"Another player already claimed this transaction."},
    {~"iap.record_failed", 500, ~"The verified transaction could not be recorded."},

    %% Friends, groups, direct messages.
    {~"social.cannot_friend_self", 400, ~"A player cannot befriend themselves."},
    {~"social.friend_not_found", 404, ~"No player exists with this friend id."},
    {~"social.already_friend", 409, ~"This friendship already exists."},
    {~"social.friendship_not_found", 404, ~"No friendship exists between these players."},
    {~"social.group_not_found", 404, ~"No group exists with this id."},
    {~"social.group_closed", 403, ~"This group is closed and needs an invite."},
    {~"social.group_full", 409, ~"This group already holds as many members as allowed."},
    {~"social.already_member", 409, ~"This player is already a member of the group."},
    {~"social.invalid_role", 400, ~"That is not a role this group defines."},
    {~"social.member_not_found", 404, ~"No such member in this group."},
    {~"dm.blocked", 403, ~"The recipient blocked this sender."},
    {~"dm.content_empty", 400, ~"A direct message needs content."},
    {~"dm.content_too_large", 413, ~"The message is longer than the server accepts."},

    %% Tournaments and notifications.
    {~"tournament.not_found", 404, ~"No tournament exists with this id."},
    {~"tournament.full", 409, ~"This tournament holds as many entrants as allowed."},
    {~"tournament.already_joined", 409, ~"This player already entered the tournament."},
    {~"notification.not_found", 404, ~"No notification exists with this id."},

    %% Ops read plane.
    {~"ops.invalid_board_id", 400, ~"The leaderboard id is missing or too long."},
    {~"ops.invalid_id", 400, ~"The id is missing or not the shape this endpoint accepts."},
    {~"ops.invalid_filter", 400, ~"That filter value is not the shape its column holds."},
    {~"ops.not_found", 404, ~"No record exists with this id."},
    {~"ops.unknown_sort_field", 400, ~"That is not a field this endpoint sorts on."},
    {~"ops.unknown_sort_order", 400, ~"`order` must be \"asc\" or \"desc\"."},
    {~"ops.query_failed", 500, ~"The ops query failed."},

    %% Account lifecycle. The confirmation codes are what stop an erasure from
    %% being a single click a page can be tricked into making.
    {
        ~"ops.confirmation_required",
        400,
        ~"An erasure must echo the player's username in the request body."
    },
    {
        ~"ops.confirmation_mismatch",
        400,
        ~"The username in the request body is not this player's username."
    },
    {~"ops.erase_failed", 500, ~"The erasure was rolled back and nothing was deleted."},
    {
        ~"ops.invalid_cutoff",
        400,
        ~"A guest purge must name `inactive_for_seconds` as a whole number of seconds, 0 or more."
    },
    {
        ~"ops.purge_count_mismatch",
        409,
        ~"The cohort is no longer the size the request confirmed. Nothing was deleted."
    },
    {~"ops.purge_failed", 500, ~"The cohort could not be selected. Nothing was deleted."},
    {
        ~"ops.orphaned_extension_rows",
        409,
        ~"A removed extension's rows still reference this player and block the erase. Reinstall the package so its erase sweep runs, or purge its tables."
    },
    {
        ~"ops.export_incomplete",
        500,
        ~"An installed extension failed to export. No export was produced."
    },

    %% Operator console. One 404 covers both "this node does not serve the
    %% console" and "no such asset", so a caller cannot tell a deployment that
    %% has the console switched off from one that has it on.
    {~"console.not_found", 404, ~"No console resource exists at this path."},
    {~"console.not_built", 503, ~"The console bundle is not built into this release."},

    %% Cloud saves. save.not_found is also what the slot-keyed /saves routes
    %% return when storage is switched off at the release level
    %% (asobi_storage:enabled/0), so a disabled deployment reads the same as an
    %% empty one - see asobi_storage_controller.
    {~"save.not_found", 404, ~"No cloud save exists in this slot."},
    {~"save.too_large", 413, ~"The save data is larger than the per-slot limit."},
    {~"save.version_conflict", 409, ~"The slot was written by another client."},
    {~"save.slot_limit_reached", 409, ~"The player has no free cloud-save slots."},

    %% Generic storage. storage.not_found is also what the /storage routes
    %% return when storage is switched off (asobi_storage:enabled/0), the
    %% collection/key counterpart to save.not_found for the /saves routes: each
    %% family answers with its own genuine-miss code so the off-state cannot be
    %% fingerprinted against an enabled but empty deployment.
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
    {~"match.full", 409, ~"The match has no room for another player."},
    {~"match.locked", 409, ~"The match is closed to new players."},
    {~"match.join_refused", 403, ~"The game refused this join. See `details.refused_reason`."},
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
    {~"match_full", ~"match.full"},
    {~"match_locked", ~"match.locked"},
    {~"join_refused", ~"match.join_refused"},
    {~"world_not_found", ~"world.not_found"},
    {~"already_in_world", ~"world.already_joined"},
    {~"invalid_channel_id", ~"chat.invalid_channel_id"},
    {~"too_many_channels", ~"chat.too_many_channels"},
    {~"unknown_mode", ~"matchmaker.unknown_mode"},
    {~"queue_full", ~"matchmaker.queue_full"},
    {~"not_owner", ~"forbidden"},
    {~"blocked", ~"dm.blocked"},
    {~"content_empty", ~"dm.content_empty"},
    {~"content_too_large", ~"dm.content_too_large"}
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

-doc """
A Nova `{json, ...}` result carrying the object for `Code` plus `Extra`.

For the routes that answered with more than an `error` string before the
object existed. `Extra` is those top-level keys, unchanged, so a client reading
`fields` or `retry_after` keeps working; the same map is the object's
`details`. The status still comes from the code.
""".
-spec legacy(code(), details()) -> {json, pos_integer(), #{}, map()}.
legacy(Code, Extra) ->
    {json, status(Code), #{}, legacy_body(Code, Extra)}.

-doc """
`legacy/2`'s body, for a caller that writes the response itself.

The plugins reply through `cowboy_req` rather than returning to Nova.
""".
-spec legacy_body(code(), details()) -> map().
legacy_body(Code, Extra) when is_map(Extra) ->
    maps:merge(Extra, object(Code, Extra)).

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

-doc """
Every defined code: core's, plus every installed extension's.

The client-facing contract, enumerated. Use `core_codes/0` when the question
is what asobi itself defines.
""".
-spec codes() -> [code()].
codes() ->
    core_codes() ++ lists:sort(maps:keys(asobi_extensions:error_codes())).

-doc """
The codes asobi itself defines.

`m:asobi_extension_reserved` derives core's reserved RPC prefixes from these
domains, and must not see extension codes: an extension would then be told it
claims a namespace it owns.
""".
-spec core_codes() -> [code()].
core_codes() ->
    [Code || {Code, _, _} <- ?CODES].

-doc """
Whether `Code` is defined by core or by an installed extension.

For a caller that reports an error on a surface with no Nova return handler
to log for it - `m:asobi_rpc` - and must not let an undefined code reach a
client unnoticed.
""".
-spec defined(code()) -> boolean().
defined(Code) when is_binary(Code) ->
    entry(Code) =/= false.

-doc """
The error object for a WebSocket `reason` string.

`reason` is the pre-existing WebSocket error dialect and stays on the wire
untouched; this maps it onto a code. A reason with no code of its own becomes
`ws.request_failed` with the raw reason in `details` - script-supplied strings
must not be able to mint codes.
""".
-spec from_ws_reason(atom() | binary()) -> object().
from_ws_reason(Reason) ->
    from_ws_reason(Reason, #{}).

-doc """
`from_ws_reason/1` with extra `details`.

For the caller that has context the code alone cannot carry - the game's own
refusal string behind `match.join_refused`, say. The details are additive:
they never replace the code, so a script-supplied string still cannot become
one.
""".
-spec from_ws_reason(atom() | binary(), details()) -> object().
from_ws_reason(Reason, Details) when is_atom(Reason) ->
    from_ws_reason(atom_to_binary(Reason, utf8), Details);
from_ws_reason(Reason, Details) when is_binary(Reason), is_map(Details) ->
    case lists:keyfind(Reason, 1, ?WS_REASONS) of
        {_, Code} when is_binary(Code) -> object(Code, Details);
        _ -> object(~"ws.request_failed", Details#{reason => Reason})
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
    case lists:keyfind(Code, 1, ?CODES) of
        false -> extension_entry(Code);
        Entry -> Entry
    end.

extension_entry(Code) ->
    case maps:find(Code, asobi_extensions:error_codes()) of
        {ok, {Status, Message}} -> {Code, Status, Message};
        error -> false
    end.

%% A code outside ?CODES reached a client: the contract says clients may
%% branch on `code`, so an undefined one is a defect that must not stay
%% silent.
-spec log_undefined(code()) -> ok.
log_undefined(Code) ->
    case entry(Code) of
        false -> ?LOG_ERROR(#{event => undefined_error_code, code => Code});
        _ -> ok
    end.
