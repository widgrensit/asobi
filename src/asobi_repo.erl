-module(asobi_repo).
-behaviour(kura_repo).

-include_lib("kura/include/kura.hrl").

-export([
    otp_app/0,
    migration_apps/0,
    all/1,
    aggregate/2,
    get/2,
    insert/1,
    insert/2,
    update/1,
    delete/1,
    delete/2,
    update_all/2,
    delete_all/1,
    insert_all/2,
    exists/1,
    reload/2,
    transaction/1,
    multi/1,
    preload/3
]).

-spec otp_app() -> asobi.
otp_app() -> asobi.

-doc """
The applications kura runs migrations from, beyond asobi itself: every
installed extension.

Inert on the pinned kura. `kura_migrator` there discovers migrations from
exactly one application - `application:get_application(RepoMod)` - so an
extension's migrations do not run and its tables are created by nothing. That
is a kura defect independent of extensions: `asobi_gdpr` declares three
schemas and no migration in any repo creates those tables.

kura 2.20 adds multi-application discovery and calls this optional `kura_repo`
callback. asobi pins `{kura, "~> 2.17"}`, where nothing calls it, so this is a
seam and not yet a behaviour change. Moving the pin is the whole of the
change: extension migrations then run inside core's transaction, under one
advisory lock.

kura adds the repo's own application and topologically sorts the result by
each application's OTP `applications` key, so this returns the extensions
only and does not restate an ordering kura already derives.
""".
-spec migration_apps() -> [atom()].
migration_apps() ->
    [App || #{app := App} <- asobi_extensions:resolve()].

-spec all(#kura_query{}) -> {ok, [map()]} | {error, term()}.
all(Q) -> kura_repo_worker:all(?MODULE, Q).

-spec aggregate(#kura_query{}, count | {count | sum | avg | min | max, atom()}) ->
    {ok, term()} | {error, term()}.
aggregate(Q, Agg) -> kura_repo_worker:aggregate(?MODULE, Q, Agg).

-spec get(module(), term()) -> {ok, map()} | {error, term()}.
get(Schema, Id) -> kura_repo_worker:get(?MODULE, Schema, Id).

-spec insert(#kura_changeset{}) -> {ok, map()} | {error, term()}.
insert(CS) -> kura_repo_worker:insert(?MODULE, CS).

-spec insert(#kura_changeset{}, map()) -> {ok, map()} | {error, term()}.
insert(CS, Opts) -> kura_repo_worker:insert(?MODULE, CS, Opts).

-spec update(#kura_changeset{}) -> {ok, map()} | {error, term()}.
update(CS) -> kura_repo_worker:update(?MODULE, CS).

-spec delete(#kura_changeset{}) -> {ok, map()} | {error, term()}.
delete(CS) -> kura_repo_worker:delete(?MODULE, CS).

-spec delete(module(), map()) -> {ok, map()} | {error, term()}.
delete(Schema, Record) ->
    CS = kura_changeset:cast(Schema, Record, #{}, []),
    kura_repo_worker:delete(?MODULE, CS).

-spec update_all(#kura_query{}, map()) -> {ok, non_neg_integer()} | {error, term()}.
update_all(Q, Updates) -> kura_repo_worker:update_all(?MODULE, Q, Updates).

-spec delete_all(#kura_query{}) -> {ok, non_neg_integer()} | {error, term()}.
delete_all(Q) -> kura_repo_worker:delete_all(?MODULE, Q).

-spec insert_all(module(), [map()]) -> {ok, non_neg_integer()} | {error, term()}.
insert_all(Schema, Entries) -> kura_repo_worker:insert_all(?MODULE, Schema, Entries).

-spec exists(#kura_query{}) -> {ok, boolean()} | {error, term()}.
exists(Q) -> kura_repo_worker:exists(?MODULE, Q).

-spec reload(module(), map()) -> {ok, map()} | {error, term()}.
reload(Schema, Record) -> kura_repo_worker:reload(?MODULE, Schema, Record).

-spec transaction(fun()) -> term().
transaction(Fun) -> kura_repo_worker:transaction(?MODULE, Fun).

-spec multi(term()) -> {ok, map()} | {error, atom(), term(), map()}.
multi(M) -> kura_repo_worker:multi(?MODULE, M).

-spec preload(module(), map() | [map()], [atom()]) -> map() | [map()].
preload(Schema, Records, Assocs) -> kura_repo_worker:preload(?MODULE, Schema, Records, Assocs).
