-module(asobi_id).
-moduledoc """
UUIDv7 generation for Asobi entities.

Generates UUIDv7 (RFC 9562) identifiers via `jhn_uuid`. UUIDv7 embeds a
millisecond timestamp in the high 48 bits, giving time-ordered IDs that
improve PostgreSQL B-tree index locality, reduce WAL writes, and enable
native time-range queries on primary keys.
""".

-export([generate/0]).

-doc "Generate a UUIDv7 as a lowercase hyphenated binary string.".
-spec generate() -> binary().
generate() ->
    case jhn_uuid:gen(v7) of
        UUID when is_list(UUID) -> iolist_to_binary(UUID)
    end.
