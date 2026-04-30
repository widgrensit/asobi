-module(asobi_id).
-moduledoc """
UUIDv7 generation for Asobi entities.

Generates UUIDv7 (RFC 9562) identifiers via `jhn_uuid`. UUIDv7 embeds a
millisecond timestamp in the high 48 bits, giving time-ordered IDs that
improve PostgreSQL B-tree index locality, reduce WAL writes, and enable
native time-range queries on primary keys.

**Privacy note (F-31)**: the embedded timestamp leaks the creation
time of any id we expose. Match ids, world ids, ticket ids and similar
ephemeral resources are an accepted trade-off, but `player.id` —
which uses the same generator and persists for life — also reveals
account-creation time. Treat the trade-off as acceptable for this
codebase; if a future requirement needs unguessable, non-correlatable
ids (e.g. for tokens, invite codes, etc.) generate them via
`crypto:strong_rand_bytes/1` rather than this function.
""".

-export([generate/0]).

-doc "Generate a UUIDv7 as a lowercase hyphenated binary string.".
-spec generate() -> binary().
generate() ->
    case jhn_uuid:gen(v7) of
        UUID when is_list(UUID) -> iolist_to_binary(UUID)
    end.
