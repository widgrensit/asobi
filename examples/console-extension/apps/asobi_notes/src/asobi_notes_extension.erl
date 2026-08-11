%% The manifest. Note what is NOT here: the console screens.
%%
%% They are React source at priv/console/index.jsx, and they are found by being
%% there - the same way migrations and Kura schemas are discovered rather than
%% announced. There is no console callback to declare.
-module(asobi_notes_extension).
-behaviour(asobi_extension).

-export([info/0, ops/0, sup/0, owns/0, codes/0]).

-spec info() -> asobi_extension:info().
info() -> #{name => notes, extension_version => 1}.

%% Two actions, two classes. A console session holds every class but `erasure`,
%% so both are reachable from the console; the split is what makes the write
%% refusable for a minted bearer token that holds `read` alone. Anything but
%% `get` is wrapped in
%% asobi_ops_audit:mutation/4 by core before it runs, so every note written from
%% the console has a durable row naming the operator - the extension does
%% nothing to arrange that and cannot opt out of it.
-spec ops() -> asobi_extension:ops().
ops() ->
    #{
        ~"list" => #{method => get, mfa => {asobi_notes_ops, list, 2}, class => read},
        ~"add" => #{method => post, mfa => {asobi_notes_ops, add, 2}, class => config}
    }.

%% A library application: no `mod` in the .app.src, so core supervises this.
%% An extension supervising itself can take the node with it - see
%% m:asobi_extension_sup.
-spec sup() -> [supervisor:child_spec()].
sup() ->
    [#{id => asobi_notes, start => {asobi_notes, start_link, []}}].

%% No tables: this example holds its notes in ETS so it needs no migration and
%% no database, which keeps it about the console seam and nothing else. A real
%% extension would own a table here.
-spec owns() -> asobi_extension:owns().
owns() -> #{rpc => [~"notes"]}.

%% Without this, an ordinary domain failure answers 500 and logs as a core
%% defect. The domain must be an RPC prefix this extension owns.
-spec codes() -> asobi_extension:codes().
codes() ->
    #{~"notes.empty" => #{status => 400, message => ~"A note needs a body."}}.
