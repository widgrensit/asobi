-module(asobi_ops_controller).
-moduledoc """
HTTP surface of the ops plane: every read, plus the two account-lifecycle
routes.

Every list endpoint here returns the same envelope, clamps its own paging, and
rejects a sort field it does not recognise with 400 rather than ordering by
something the caller did not ask for.

These routes are mounted behind `asobi_ops_auth:verify/1`, the operator
capability check (ADR 0007) - never the player-scoped bearer check the rest of
`/api/v1` uses, which would let any authenticated player, guest included,
enumerate the deployment. Every read projection here is still held to exactly
what the equivalent public endpoint already exposes.

`erase_player/1` and `export_player/1` are the exceptions to that last
sentence, deliberately: an operator answering a deletion or access request
needs more than a player's own profile view. They are the only two routes on
this plane that are not reads, they carry their own capability classes
(`erasure` and `player_data`), and the erasure is audited inside its own
transaction. See `m:asobi_player_erase`.
""".

-include_lib("kernel/include/logger.hrl").
-include_lib("kura/include/kura.hrl").

-export([players/1, player/1, erase_player/1, export_player/1, purge_guests/1]).
-export([matches/1, match/1, features/1, stats/1]).
-export([leaderboards/1, leaderboard_entries/1, matchmaker/1]).
-export([economy_items/1, economy_item/1, economy_listings/1, economy_listing/1]).
-export([chat_channels/1, chat_messages/1]).
-export([tournaments/1, tournament/1, notifications/1]).

-type response() ::
    {json, map()}
    | {json, integer(), map(), map()}
    | {asobi_error, asobi_error:code()}
    | {asobi_error, asobi_error:code(), asobi_error:details()}.

%% `leaderboard_id` is a VARCHAR(255); a longer binding matches no board, so
%% it is answered as a bad request rather than paid for as a query.
-define(MAX_BOARD_ID_BYTES, 255).

%% `channel_id` is the same VARCHAR(255), and the same reasoning.
-define(MAX_CHANNEL_ID_BYTES, 255).

-spec players(cowboy_req:req()) -> response().
players(Req) ->
    list(Req, fun asobi_ops_players:query/1, fun asobi_ops_players:project/1).

-spec player(cowboy_req:req()) -> response().
player(Req) ->
    lookup(Req, asobi_player, fun asobi_ops_players:project/1).

-doc """
Erase one player and everything core holds about them. Irreversible.

The body must echo the player's `username`, and the echo is checked against
the row server-side. That guard is not distribution-shaped - the limitation it
answers is a human clicking the wrong row, or a page being clickjacked into
posting on the operator's behalf - so OTP does not dissolve it. It costs one
comparison and makes an unattended POST insufficient.
""".
-spec erase_player(cowboy_req:req()) -> response().
erase_player(#{bindings := #{~"id" := Id}, auth_data := #{ops_actor := Actor}} = Req) ->
    case asobi_ops_params:uuid(Id) of
        true -> confirmed_erase(Id, echoed_username(Req), Actor);
        false -> {asobi_error, ~"ops.invalid_id"}
    end.

-doc """
Everything core holds about one player, as one JSON object.

`player_data`, not `read`: a leaderboard view is one thing, and the whole of
one identified person's record is another.
""".
-spec export_player(cowboy_req:req()) -> response().
export_player(#{bindings := #{~"id" := Id}}) ->
    case asobi_ops_params:uuid(Id) of
        true -> exported(asobi_player_export:run(Id));
        false -> {asobi_error, ~"ops.invalid_id"}
    end.

-spec exported(
    {ok, map()} | {error, not_found | {extension_export, asobi_extension:name(), term()}}
) -> response().
exported({ok, Payload}) -> {json, #{data => Payload}};
exported({error, not_found}) -> {asobi_error, ~"ops.not_found"};
exported({error, {extension_export, _Name, _Reason}}) -> {asobi_error, ~"ops.export_incomplete"}.

-spec confirmed_erase(binary(), binary() | undefined, asobi_ops_auth:actor()) -> response().
confirmed_erase(_Id, undefined, _Actor) ->
    {asobi_error, ~"ops.confirmation_required"};
confirmed_erase(Id, Echoed, Actor) ->
    case asobi_repo:get(asobi_player, Id) of
        {ok, #{username := Echoed}} -> erased(asobi_player_erase:run(Id, Actor), Id);
        {ok, _Other} -> {asobi_error, ~"ops.confirmation_mismatch"};
        {error, not_found} -> {asobi_error, ~"ops.not_found"};
        {error, Reason} -> error_response({query_failed, Reason})
    end.

-spec erased({ok, map()} | {error, term()}, binary()) -> response().
erased({ok, Summary}, _Id) ->
    {json, #{data => Summary}};
erased({error, forbidden}, _Id) ->
    {asobi_error, ~"forbidden"};
erased({error, not_found}, _Id) ->
    {asobi_error, ~"ops.not_found"};
erased({error, {orphaned_extension_rows, Blocker}}, Id) ->
    ?LOG_ERROR(#{
        msg => ~"ops player erase blocked by orphaned extension rows",
        player_id => Id,
        table => Blocker
    }),
    {asobi_error, ~"ops.orphaned_extension_rows", #{table => blocker_detail(Blocker)}};
erased({error, Reason}, Id) ->
    ?LOG_ERROR(#{msg => ~"ops player erase failed", player_id => Id, reason => Reason}),
    {asobi_error, ~"ops.erase_failed"}.

-spec blocker_detail(term()) -> binary().
blocker_detail(Table) when is_binary(Table) -> Table;
blocker_detail(_Blocker) -> ~"unknown".

-doc """
Erase the unclaimed guests nobody has signed in as since a cutoff.

The bulk counterpart to `erase_player/1`, and it takes the same position on
confirmation from a different angle. One player is confirmed by echoing
something only a caller who looked at the row can know; a cohort has no such
handle, so what stands in for it is that **`inactive_for_seconds` has no
default**. An empty POST to this route selects nothing and answers 400, which
is the property the username echo buys over there: an unattended request is
never sufficient.

`inactive_for_seconds: 0` means "every unclaimed guest, including the one that
signed in a second ago". That is the "clear them all" case, and it is spelled
out rather than defaulted to.

Three optional keys tighten or widen it:

* `dry_run: true` counts and deletes nothing. Free, and worth doing first.
* `confirm_count: N` refuses the call unless the server counts exactly `N`
  right now. For an operator working from a preview; a live game minting
  guests will move under it, which is the point.
* `limit: N` caps this call at `N` deletions (default
  `asobi_guest_purge:default_limit/0`, ceiling `max_limit/0`). The response
  reports `remaining`, and a caller that wants the whole cohort repeats until
  it reaches `0` - one request is never held open across an unbounded table.
""".
-spec purge_guests(cowboy_req:req()) -> response().
purge_guests(#{auth_data := #{ops_actor := Actor}} = Req) ->
    case inactive_for(Req) of
        {ok, Seconds} -> counted(asobi_guest_purge:cutoff(Seconds), Req, Actor);
        error -> {asobi_error, ~"ops.invalid_cutoff"}
    end.

-spec counted(asobi_guest_purge:cutoff(), cowboy_req:req(), asobi_ops_auth:actor()) -> response().
counted(Cutoff, Req, Actor) ->
    case asobi_guest_purge:count(Cutoff) of
        {ok, Matched} ->
            case confirmed_count(Req, Matched) of
                ok -> purge_or_preview(Cutoff, Matched, Req, Actor);
                mismatch -> {asobi_error, ~"ops.purge_count_mismatch", #{matched => Matched}}
            end;
        {error, Reason} ->
            error_response({query_failed, Reason})
    end.

-spec purge_or_preview(
    asobi_guest_purge:cutoff(), non_neg_integer(), cowboy_req:req(), asobi_ops_auth:actor()
) -> response().
purge_or_preview(Cutoff, Matched, Req, Actor) ->
    case dry_run(Req) of
        true ->
            {json, #{data => summary(Matched, 0, 0, Matched, true)}};
        false ->
            case asobi_guest_purge:run(Cutoff, purge_limit(Req), Matched, Actor) of
                {ok, #{deleted := Deleted, skipped := Skipped}} ->
                    {json, #{
                        data => summary(Matched, Deleted, Skipped, Matched - Deleted, false)
                    }};
                {error, Reason} ->
                    ?LOG_ERROR(#{msg => ~"ops guest purge failed", reason => Reason}),
                    {asobi_error, ~"ops.purge_failed"}
            end
    end.

%% `remaining` is the count this call started from minus what it erased, not a
%% second count: a re-count here would read a table other requests are still
%% writing to and report a number that was never true of this call. It is what
%% is left of the cohort this call measured, which is the question a caller
%% looping on it is asking.
-spec summary(
    non_neg_integer(), non_neg_integer(), non_neg_integer(), integer(), boolean()
) -> map().
summary(Matched, Deleted, Skipped, Remaining, DryRun) ->
    #{
        matched => Matched,
        deleted => Deleted,
        skipped => Skipped,
        remaining => max(0, Remaining),
        dry_run => DryRun
    }.

%% Absent, wrong-typed and negative are one answer, because none of them says
%% which cohort to delete. A float is not "close enough" to a cutoff either.
-spec inactive_for(cowboy_req:req()) -> {ok, non_neg_integer()} | error.
inactive_for(#{json := #{~"inactive_for_seconds" := Seconds}}) when
    is_integer(Seconds), Seconds >= 0
->
    {ok, Seconds};
inactive_for(_Req) ->
    error.

-spec dry_run(cowboy_req:req()) -> boolean().
dry_run(#{json := #{~"dry_run" := true}}) -> true;
dry_run(_Req) -> false.

-spec confirmed_count(cowboy_req:req(), non_neg_integer()) -> ok | mismatch.
confirmed_count(#{json := #{~"confirm_count" := Matched}}, Matched) when is_integer(Matched) -> ok;
confirmed_count(#{json := #{~"confirm_count" := Given}}, _Matched) when is_integer(Given) ->
    mismatch;
confirmed_count(_Req, _Matched) ->
    ok.

%% Clamped rather than rejected: an oversized batch is a caller asking for more
%% work in one request than this route will hold open, and the honest answer is
%% the batch it will do plus the `remaining` that says to call again.
-spec purge_limit(cowboy_req:req()) -> pos_integer().
purge_limit(#{json := #{~"limit" := Limit}}) when is_integer(Limit), Limit > 0 ->
    min(Limit, asobi_guest_purge:max_limit());
purge_limit(_Req) ->
    asobi_guest_purge:default_limit().

%% `undefined` is "no confirmation sent", which is a different answer from a
%% confirmation that did not match - an operator who typed the wrong name
%% should be told so.
-spec echoed_username(cowboy_req:req()) -> binary() | undefined.
echoed_username(#{json := #{~"username" := Username}}) when is_binary(Username) -> Username;
echoed_username(_Req) -> undefined.

-spec matches(cowboy_req:req()) -> response().
matches(Req) ->
    list(Req, fun asobi_ops_matches:query/1, fun asobi_ops_matches:project/1).

-spec match(cowboy_req:req()) -> response().
match(Req) ->
    lookup(Req, asobi_match_record, fun asobi_ops_matches:project/1).

-spec economy_items(cowboy_req:req()) -> response().
economy_items(Req) ->
    list(Req, fun asobi_ops_economy:items_query/1, fun asobi_ops_economy:project_item/1).

-spec economy_item(cowboy_req:req()) -> response().
economy_item(Req) ->
    lookup(Req, asobi_item_def, fun asobi_ops_economy:project_item/1).

-spec economy_listings(cowboy_req:req()) -> response().
economy_listings(Req) ->
    list(Req, fun asobi_ops_economy:listings_query/1, fun asobi_ops_economy:project_listing/1).

-spec economy_listing(cowboy_req:req()) -> response().
economy_listing(Req) ->
    lookup(Req, asobi_store_listing, fun asobi_ops_economy:project_listing/1).

-spec tournaments(cowboy_req:req()) -> response().
tournaments(Req) ->
    list(Req, fun asobi_ops_tournaments:query/1, fun asobi_ops_tournaments:project/1).

-spec tournament(cowboy_req:req()) -> response().
tournament(Req) ->
    lookup(Req, asobi_tournament, fun asobi_ops_tournaments:project/1).

-spec notifications(cowboy_req:req()) -> response().
notifications(Req) ->
    list(Req, fun asobi_ops_notifications:query/1, fun asobi_ops_notifications:project/1).

-spec chat_channels(cowboy_req:req()) -> response().
chat_channels(Req) ->
    rows(Req, fun asobi_ops_chat:channels/1, fun asobi_ops_chat:project_channel/1).

%% The channel id is a free-form string, not a uuid, so it is bounded rather
%% than shape-checked.
-spec chat_messages(cowboy_req:req()) -> response().
chat_messages(#{bindings := #{~"id" := ChannelId}} = Req) when
    is_binary(ChannelId), ChannelId =/= ~"", byte_size(ChannelId) =< ?MAX_CHANNEL_ID_BYTES
->
    list(
        Req,
        fun(Params) -> asobi_ops_chat:messages_query(ChannelId, Params) end,
        fun asobi_ops_chat:project_message/1
    );
chat_messages(_Req) ->
    {asobi_error, ~"ops.invalid_id"}.

-spec features(cowboy_req:req()) -> response().
features(_Req) ->
    {json, asobi_ops_features:features()}.

-spec stats(cowboy_req:req()) -> response().
stats(_Req) ->
    {json, asobi_ops_stats:collect()}.

-spec leaderboards(cowboy_req:req()) -> response().
leaderboards(Req) ->
    rows(Req, fun asobi_ops_leaderboards:boards/1, fun asobi_ops_leaderboards:project_board/1).

-spec leaderboard_entries(cowboy_req:req()) -> response().
leaderboard_entries(#{bindings := #{~"id" := BoardId}} = Req) when
    is_binary(BoardId), BoardId =/= ~"", byte_size(BoardId) =< ?MAX_BOARD_ID_BYTES
->
    list(
        Req,
        fun(Params) -> asobi_ops_leaderboards:entries_query(BoardId, Params) end,
        fun asobi_ops_leaderboards:project_entry/1
    );
leaderboard_entries(_Req) ->
    {asobi_error, ~"ops.invalid_board_id"}.

%% The snapshot is read once and used for both halves of the response, so the
%% totals and the rows can never describe two different samples.
-spec matchmaker(cowboy_req:req()) -> response().
matchmaker(Req) ->
    Params = params(Req),
    Snapshot = asobi_matchmaker:snapshot(),
    case asobi_ops_matchmaker:rows(Snapshot, Params) of
        {ok, {Rows, Orders}} ->
            Envelope = asobi_ops_page:slice(
                Rows,
                Orders,
                asobi_ops_params:page(Params),
                fun asobi_ops_matchmaker:project/1
            ),
            {json, Envelope#{queue => asobi_ops_matchmaker:summary(Snapshot)}};
        {error, Reason} ->
            error_response(Reason)
    end.

-spec list(
    cowboy_req:req(),
    fun((asobi_ops_params:params()) -> {ok, #kura_query{}} | {error, term()}),
    fun((map()) -> map())
) -> response().
list(Req, BuildQuery, Project) ->
    Params = params(Req),
    case BuildQuery(Params) of
        {ok, Query} ->
            page(Query, asobi_ops_params:page(Params), Project);
        {error, Reason} ->
            error_response(Reason)
    end.

%% The single-row envelope: `{"data": {...}}`, the list envelope minus the
%% `page` key it has nothing to report. A console reads `data` either way.
-spec lookup(cowboy_req:req(), module(), fun((map()) -> map())) -> response().
lookup(#{bindings := #{~"id" := Id}}, Schema, Project) ->
    case asobi_ops_lookup:fetch(Schema, Id, Project) of
        {ok, Row} -> {json, #{data => Row}};
        {error, Reason} -> error_response(Reason)
    end;
lookup(_Req, _Schema, _Project) ->
    {asobi_error, ~"ops.invalid_id"}.

-spec rows(
    cowboy_req:req(),
    fun(
        (asobi_ops_params:params()) ->
            {ok, {[map()], asobi_ops_params:sort_spec()}} | {error, term()}
    ),
    fun((map()) -> map())
) -> response().
rows(Req, BuildRows, Project) ->
    Params = params(Req),
    case BuildRows(Params) of
        {ok, {Rows, Orders}} ->
            {json, asobi_ops_page:slice(Rows, Orders, asobi_ops_params:page(Params), Project)};
        {error, Reason} ->
            error_response(Reason)
    end.

-spec page(#kura_query{}, asobi_ops_params:page_spec(), fun((map()) -> map())) -> response().
page(Query, PageSpec, Project) ->
    case asobi_ops_page:list(Query, PageSpec, Project) of
        {ok, Envelope} -> {json, Envelope};
        {error, Reason} -> error_response({query_failed, Reason})
    end.

-spec params(cowboy_req:req()) -> asobi_ops_params:params().
params(#{parsed_qs := Params}) when is_map(Params) -> Params;
params(_Req) -> #{}.

%% A rejected parameter is the caller's fault and says which one; a failed
%% read is ours and says nothing beyond that, with the reason in the log.
%%
%% `field` and `order` were top-level keys before the shared object existed
%% and stay there; they are the object's `details` too. Both are echoed back
%% from the caller's own query string, so neither can become a code.
-spec error_response(term()) -> response().
error_response({unknown_sort, Field}) ->
    asobi_error:legacy(~"ops.unknown_sort_field", #{field => Field});
error_response({unknown_order, Order}) ->
    asobi_error:legacy(~"ops.unknown_sort_order", #{order => Order});
error_response({invalid_filter, Field}) ->
    {asobi_error, ~"ops.invalid_filter", #{field => Field}};
error_response(invalid_id) ->
    {asobi_error, ~"ops.invalid_id"};
error_response(not_found) ->
    {asobi_error, ~"ops.not_found"};
error_response({query_failed, Reason}) ->
    ?LOG_ERROR(#{msg => ~"ops list query failed", reason => Reason}),
    {asobi_error, ~"ops.query_failed"};
error_response(_) ->
    {asobi_error, ~"invalid_payload"}.
