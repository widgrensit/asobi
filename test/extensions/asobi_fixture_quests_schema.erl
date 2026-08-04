-module(asobi_fixture_quests_schema).
-moduledoc "A kura schema belonging to an extension, so its table claim is derivable.".

-export([table/0, fields/0]).

-spec table() -> binary().
table() ->
    ~"quest_progress".

-spec fields() -> [].
fields() ->
    [].
