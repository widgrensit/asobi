-module(asobi_discovery).
-moduledoc """
Shared enumeration for the discovery surfaces.

Worlds and matches both register as `{ServerMod, Id}` in the `nova_scope`
pg scope and both expose `get_info/1` plus `listing_info/1`, so browsing
either is the same walk: enumerate the live processes, apply the caller's
filter to the full info, and return the listing projection.

Enumeration is a pull, not a push. Worlds churn on *attributes* — the set
of worlds is near-static while occupancy changes constantly — so a delta
stream would fan out at a rate set by other players' behaviour, with no
ceiling. The 500ms cache in front of this is a hard ceiling of two
refreshes per second regardless of load. See `asobi_world_lobby`.
""".

-export([enumerate/3, cache_lookup/2]).

-define(PG_SCOPE, nova_scope).
-define(LIST_CACHE_TAB, asobi_world_lobby_cache).

-doc """
List live `ServerMod` processes whose info satisfies `FilterFun`, each as
its `ServerMod:listing_info/1` projection.

`ServerMod` is both the pg group tag and the module supplying `get_info/1`
and `listing_info/1`. A process that dies mid-enumeration, or whose
`get_info/1` fails, is skipped rather than failing the whole listing.
""".
-spec enumerate(module(), map(), fun((map(), map()) -> boolean())) -> [map()].
enumerate(ServerMod, Filters, FilterFun) ->
    Pids = [
        Pid
     || {Mod, _Id} = Group <- pg:which_groups(?PG_SCOPE),
        Mod =:= ServerMod,
        Pid <- take_first(pg:get_members(?PG_SCOPE, Group))
    ],
    lists:filtermap(
        fun(Pid) ->
            try ServerMod:get_info(Pid) of
                Info when is_map(Info) ->
                    case FilterFun(Info, Filters) of
                        true -> {true, ServerMod:listing_info(Info)};
                        false -> false
                    end;
                _ ->
                    false
            catch
                _:_ -> false
            end
        end,
        Pids
    ).

-doc """
Read a cached listing, or `miss` if absent or expired.

The table is owned and written by `asobi_world_lobby_server`; reads are
direct (the table is protected) so a browse costs no round-trip.
`badarg` before the owner has started is a miss, not a crash.
""".
-spec cache_lookup(term(), integer()) -> {hit, [map()]} | miss.
cache_lookup(Key, Now) ->
    try ets:lookup(?LIST_CACHE_TAB, Key) of
        [{_, Listing, ExpiresAt}] when ExpiresAt > Now -> {hit, Listing};
        _ -> miss
    catch
        error:badarg -> miss
    end.

%% A pg group holds one pid per world/match; extra members would mean a
%% duplicate registration, and listing the same world twice is worse than
%% ignoring the duplicate.
-spec take_first([pid()]) -> [pid()].
take_first([Pid | _]) -> [Pid];
take_first([]) -> [].
