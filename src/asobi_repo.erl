-module(asobi_repo).
-behaviour(kura_repo).

-export([
    otp_app/0,
    all/1,
    get/2,
    insert/1,
    insert/2,
    update/1,
    delete/1,
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


-spec all(kura_query:query()) -> {ok, [map()]} | {error, term()}.
all(Q) -> kura_repo_worker:all(?MODULE, Q).

-spec get(module(), term()) -> {ok, map()} | {error, term()}.
get(Schema, Id) -> kura_repo_worker:get(?MODULE, Schema, Id).

-spec insert(kura_changeset:changeset()) -> {ok, map()} | {error, term()}.
insert(CS) -> kura_repo_worker:insert(?MODULE, CS).

-spec insert(kura_changeset:changeset(), map()) -> {ok, map()} | {error, term()}.
insert(CS, Opts) -> kura_repo_worker:insert(?MODULE, CS, Opts).

-spec update(kura_changeset:changeset()) -> {ok, map()} | {error, term()}.
update(CS) -> kura_repo_worker:update(?MODULE, CS).

-spec delete(kura_changeset:changeset()) -> {ok, map()} | {error, term()}.
delete(CS) -> kura_repo_worker:delete(?MODULE, CS).

-spec update_all(kura_query:query(), map()) -> {ok, non_neg_integer()}.
update_all(Q, Updates) -> kura_repo_worker:update_all(?MODULE, Q, Updates).

-spec delete_all(kura_query:query()) -> {ok, non_neg_integer()}.
delete_all(Q) -> kura_repo_worker:delete_all(?MODULE, Q).

-spec insert_all(module(), [map()]) -> {ok, non_neg_integer()}.
insert_all(Schema, Entries) -> kura_repo_worker:insert_all(?MODULE, Schema, Entries).

-spec exists(kura_query:query()) -> {ok, boolean()}.
exists(Q) -> kura_repo_worker:exists(?MODULE, Q).

-spec reload(module(), map()) -> {ok, map()} | {error, term()}.
reload(Schema, Record) -> kura_repo_worker:reload(?MODULE, Schema, Record).

-spec transaction(fun()) -> {ok, term()} | {error, term()}.
transaction(Fun) -> kura_repo_worker:transaction(?MODULE, Fun).

-spec multi(kura_multi:multi()) -> {ok, map()} | {error, atom(), term(), map()}.
multi(M) -> kura_repo_worker:multi(?MODULE, M).

-spec preload(module(), map() | [map()], [atom()]) -> map() | [map()].
preload(Schema, Records, Assocs) -> kura_repo_worker:preload(?MODULE, Schema, Records, Assocs).
