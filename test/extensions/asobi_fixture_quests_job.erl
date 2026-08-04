-module(asobi_fixture_quests_job).
-moduledoc "A shigoto worker belonging to an extension, so its queue claim is derivable.".

-export([queue/0, perform/1]).

-spec queue() -> binary().
queue() ->
    ~"quests".

-spec perform(map()) -> ok.
perform(_Args) ->
    ok.
