%% Operator notes, held in ETS. A real extension would use a Kura schema and a
%% generated migration; this one stays in memory so the example needs no
%% database and stays about the console.
-module(asobi_notes).
-behaviour(gen_server).

-export([start_link/0, add/3, all/0, for_player/1]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(TABLE, asobi_notes).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec add(binary(), binary(), binary()) -> {ok, map()}.
add(PlayerId, Body, Author) ->
    Note = #{
        id => integer_to_binary(erlang:unique_integer([positive, monotonic])),
        player_id => PlayerId,
        body => Body,
        author => Author,
        written_at => calendar:system_time_to_rfc3339(erlang:system_time(second), [{offset, "Z"}])
    },
    gen_server:call(?MODULE, {add, Note}).

-spec all() -> [map()].
all() ->
    lists:reverse(lists:sort([Note || {_Id, Note} <- ets:tab2list(?TABLE)])).

-spec for_player(binary()) -> [map()].
for_player(PlayerId) ->
    [Note || Note <- all(), maps:get(player_id, Note) =:= PlayerId].

-spec init([]) -> {ok, []}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set]),
    {ok, []}.

-spec handle_call(term(), gen_server:from(), []) -> {reply, term(), []}.
handle_call({add, #{id := Id} = Note}, _From, State) ->
    true = ets:insert(?TABLE, {Id, Note}),
    {reply, {ok, Note}, State}.

-spec handle_cast(term(), []) -> {noreply, []}.
handle_cast(_Message, State) ->
    {noreply, State}.
