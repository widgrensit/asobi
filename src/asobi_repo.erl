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
    preload/3,
    increment/3
]).

-spec otp_app() -> asobi.
otp_app() -> asobi.

-doc """
The applications kura runs migrations from, beyond asobi itself: every
installed extension.

kura calls this optional `kura_repo` callback for multi-application migration
discovery, so extension migrations run inside core's transaction, under one
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

-doc """
Add to integer counters on one row atomically, creating the row if absent.

`Key` is the conflict target; `Deltas` the counters to accumulate. One
statement:

```sql
INSERT INTO quest_progress (player_id, quest_id, counter, inserted_at, updated_at)
VALUES ($1, $2, $3, now(), now())
ON CONFLICT (player_id, quest_id) DO UPDATE
   SET counter = quest_progress.counter + EXCLUDED.counter, updated_at = now()
RETURNING *
```

Neither half is expressible otherwise: `update_all/2` SETs literals, and
kura's `on_conflict` overwrites with the excluded value rather than adding to
the stored one. A read-modify-write instead needs the wallet's advisory-lock
dance to stay correct under concurrency.

This is the whole of asobi's raw-SQL surface, and the shape is the point.
Every identifier in the statement is a field of `Schema`, matched against
`Schema:fields()` and rejected unless it is a plain SQL name; every caller
value is a bound parameter. So no caller-supplied string can reach the
statement, which is a promise a general `query/2` could not make and the
reason there is not one.

`Key` must be a primary key or covered by a unique index, or Postgres rejects
the conflict target. The returned map is the database row, decoded but not
cast through the schema; use `get/2` when the cast matters.

Timestamps are set when the schema declares them: `inserted_at` on the insert,
`updated_at` on both paths.
""".
-spec increment(module(), #{atom() => term()}, #{atom() => integer()}) ->
    {ok, map()} | {error, term()}.
increment(Schema, Key, Deltas) when
    is_atom(Schema), is_map(Key), is_map(Deltas), map_size(Key) > 0, map_size(Deltas) > 0
->
    case increment_statement(Schema, Key, Deltas) of
        {ok, SQL, Params} -> increment_row(SQL, Params);
        {error, _} = Error -> Error
    end;
increment(Schema, Key, Deltas) ->
    {error, {invalid_increment, Schema, Key, Deltas}}.

increment_row(SQL, Params) ->
    case kura_repo_worker:query(?MODULE, SQL, Params) of
        {ok, [Row]} -> {ok, Row};
        {ok, Rows} -> {error, {unexpected_rows, length(Rows)}};
        {error, _} = Error -> Error
    end.

increment_statement(Schema, Key, Deltas) ->
    Columns = columns(Schema),
    KeyFields = lists:sort(maps:keys(Key)),
    DeltaFields = lists:sort(maps:keys(Deltas)),
    case increment_problems(Schema, Columns, Key, KeyFields, Deltas, DeltaFields) of
        [] -> {ok, increment_sql(Schema, Columns, KeyFields, DeltaFields), values(Key, Deltas)};
        [Problem | _] -> {error, Problem}
    end.

values(Key, Deltas) ->
    [maps:get(F, Key) || F <- lists:sort(maps:keys(Key))] ++
        [maps:get(F, Deltas) || F <- lists:sort(maps:keys(Deltas))].

increment_problems(Schema, Columns, Key, KeyFields, Deltas, DeltaFields) ->
    [{unknown_field, Schema, F} || F <- KeyFields ++ DeltaFields, not is_map_key(F, Columns)] ++
        [{conflict_target_is_also_a_counter, F} || F <- DeltaFields, is_map_key(F, Key)] ++
        [{not_an_integer_delta, F, V} || F := V <- Deltas, not is_integer(V)] ++
        [
            {unsafe_identifier, Name}
         || Name <- identifiers(Schema, Columns, KeyFields ++ DeltaFields), not is_plain_name(Name)
        ].

identifiers(Schema, Columns, Fields) ->
    [Schema:table() | [maps:get(F, Columns, ~"") || F <- Fields]] ++
        [maps:get(S, Columns) || S <- [inserted_at, updated_at], is_map_key(S, Columns)].

increment_sql(Schema, Columns, KeyFields, DeltaFields) ->
    Table = Schema:table(),
    Stamps = [S || S <- [inserted_at, updated_at], is_map_key(S, Columns)],
    Inserted =
        [quote(maps:get(F, Columns)) || F <- KeyFields ++ DeltaFields] ++
            [quote(maps:get(S, Columns)) || S <- Stamps],
    Placeholders =
        [[$$, integer_to_binary(I)] || I <- lists:seq(1, length(KeyFields) + length(DeltaFields))] ++
            [~"now()" || _ <- Stamps],
    Updates =
        [accumulate(Table, maps:get(F, Columns)) || F <- DeltaFields] ++
            [
                [quote(maps:get(updated_at, Columns)), ~" = now()"]
             || lists:member(updated_at, Stamps)
            ],
    [
        ~"INSERT INTO ",
        quote(Table),
        ~" (",
        commas(Inserted),
        ~") VALUES (",
        commas(Placeholders),
        ~") ON CONFLICT (",
        commas([quote(maps:get(F, Columns)) || F <- KeyFields]),
        ~") DO UPDATE SET ",
        commas(Updates),
        ~" RETURNING *"
    ].

accumulate(Table, Column) ->
    [quote(Column), ~" = ", quote(Table), $., quote(Column), ~" + EXCLUDED.", quote(Column)].

columns(Schema) ->
    maps:from_list([
        {Name, column_name(Field)}
     || #kura_field{name = Name, virtual = false} = Field <- Schema:fields()
    ]).

column_name(#kura_field{name = Name, column = undefined}) -> atom_to_binary(Name, utf8);
column_name(#kura_field{column = Column}) -> Column.

quote(Name) -> [$", Name, $"].

commas(Parts) -> lists:join(~", ", Parts).

%% Identifiers are interpolated, not bound, so anything a quoted name could
%% not survive is refused rather than escaped.
is_plain_name(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse C =:= $_
->
    is_plain_tail(Rest);
is_plain_name(_Name) ->
    false.

is_plain_tail(<<>>) ->
    true;
is_plain_tail(<<C, Rest/binary>>) when
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $_
->
    is_plain_tail(Rest);
is_plain_tail(_Name) ->
    false.
