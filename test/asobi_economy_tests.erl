-module(asobi_economy_tests).

-include_lib("eunit/include/eunit.hrl").

%% asobi#216 security review (M1 on #255): grant_inner/4 and debit_inner/4
%% cast Opts.metadata into the transactions audit table with no in-repo
%% caller today, but as exported library entry points the cap belongs on
%% the write path, not on callers staying disciplined (mirrors #169 M3).
%% Checked before any DB call, so this needs no wallet/DB fixture - an
%% oversized blob is rejected before get_or_create_wallet/2 ever runs.
grant_inner_rejects_oversized_metadata_test() ->
    Big = #{~"blob" => binary:copy(~"x", 20000)},
    ?assertEqual(
        {error, metadata_too_large},
        asobi_economy:grant_inner(~"player-1", ~"gold", 100, #{metadata => Big})
    ).

debit_inner_rejects_oversized_metadata_test() ->
    Big = #{~"blob" => binary:copy(~"x", 20000)},
    ?assertEqual(
        {error, metadata_too_large},
        asobi_economy:debit_inner(~"player-1", ~"gold", 100, #{metadata => Big})
    ).
