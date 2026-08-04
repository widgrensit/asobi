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

-export([generate/0, rand_suffix/1]).

-doc "Generate a UUIDv7 as a lowercase hyphenated binary string.".
-spec generate() -> binary().
generate() ->
    case jhn_uuid:gen(v7) of
        UUID when is_list(UUID) -> iolist_to_binary(UUID)
    end.

-doc """
Generate a random lowercase-hex binary carrying `ByteLen` bytes of real
entropy (2x`ByteLen` hex characters). For handles that need to be
non-colliding across concurrent generation - e.g. a generated username
suffix - where a `generate/0` prefix is the wrong tool: its first
characters are pure millisecond timestamp (see the moduledoc above), so
two calls in the same millisecond produce the identical prefix.
""".
-spec rand_suffix(pos_integer()) -> binary().
rand_suffix(ByteLen) when is_integer(ByteLen), ByteLen > 0 ->
    binary:encode_hex(crypto:strong_rand_bytes(ByteLen), lowercase).
