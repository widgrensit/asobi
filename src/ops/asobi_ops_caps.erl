-module(asobi_ops_caps).
-moduledoc """
Capability classes for the ops plane, and the table that tags every route with
exactly one of them (ADR 0007).

`read` is everything non-mutating, `player_data` acts on one identified
player's data (ban, grant, broadcast, roster edits, and the full export of
one account), `config` is economy definitions, credentials and deploy-adjacent
settings. `erasure` is player erasure and nothing else. The only
authorisation decision anywhere in the plane is membership of a route's class
in the actor's `caps`.

`erasure` is its own class for one reason, and it is not sensitivity: it is
the only irreversible one. An erased account cannot be un-erased by a second
call the way a ban can be lifted, so it does not belong in the same grant as
"give this player 100 coins" - and `asobi_console_session` hands a browser
every other class by default.

Role names are deliberately absent. They are not stable wire surface -
capability classes are, and a further class later is additive the same way
`erasure` was. `asobi_saas` maps its own roles onto these classes once, at
token-mint time, so the string "owner" never reaches this plane.

A route with no entry in `classes/0` has no class and `authorised/2` denies
it, so an untagged or mis-mounted route is closed rather than open.
""".

-export([classes/0, class/2, authorised/2, class_names/0, class_of/1]).

-type class() :: read | player_data | config | erasure.
-type segment() :: binary() | '_'.
-type route() :: {atom(), [segment()], class()}.

-export_type([class/0, route/0]).

-doc """
The route table: method, path segments below `/api/v1/ops`, and class.

A router meta-test holds this table and the router's ops group to each other,
so a new ops route cannot ship untagged.
""".
-spec classes() -> [route()].
classes() ->
    [
        {get, [~"stats"], read},
        {get, [~"players"], read},
        {get, [~"players", '_'], read},
        {get, [~"matches"], read},
        {get, [~"matches", '_'], read},
        {get, [~"features"], read},
        {get, [~"leaderboards"], read},
        {get, [~"leaderboards", '_', ~"entries"], read},
        {get, [~"matchmaker"], read},
        {get, [~"economy", ~"items"], read},
        {get, [~"economy", ~"items", '_'], read},
        {get, [~"economy", ~"listings"], read},
        {get, [~"economy", ~"listings", '_'], read},
        {get, [~"chat", ~"channels"], read},
        {get, [~"chat", ~"channels", '_', ~"messages"], read},
        {get, [~"tournaments"], read},
        {get, [~"tournaments", '_'], read},
        {get, [~"notifications"], read},
        %% Not `read`. `read` grants a leaderboard view; this grants
        %% everything the deployment holds about one identified person.
        {get, [~"players", '_', ~"export"], player_data},
        {post, [~"players", '_', ~"erase"], erasure},
        %% Same class as the single erase, because it is the same action at a
        %% different fan-out. A credential trusted to erase one player is
        %% trusted to erase a cohort; one that is not, is not. Splitting it
        %% would mint a "may erase, but only slowly" capability, which nothing
        %% in the threat model asks for.
        {post, [~"players", ~"guests", ~"purge"], erasure}
    ].

-doc """
The class of an ops route, from the request method and path.

`undefined` for anything that is not a tagged ops route, including a path
outside `/api/v1/ops` and a method the table does not carry.
""".
-spec class(binary(), binary()) -> class() | undefined.
class(Method, Path) ->
    %% Split the way routing_tree does (`trim_all` collapses `//` and edge
    %% slashes) so a path variant that still routes cannot miss its tag.
    case binary:split(Path, ~"/", [global, trim_all]) of
        [~"api", ~"v1", ~"ops" | [_ | _] = Segments] -> lookup(method(Method), Segments);
        _ -> undefined
    end.

-doc "Whether an actor holding `Caps` may call a route of class `Class`.".
-spec authorised(class() | undefined, [class()]) -> boolean().
authorised(undefined, _Caps) -> false;
authorised(Class, Caps) -> lists:member(Class, Caps).

-doc "Every class, for validating one declared in an extension manifest.".
-spec class_names() -> [class()].
class_names() ->
    [read, player_data, config, erasure].

-doc """
Narrow an untrusted term to a capability class, or refuse it.

Exported so a consumer does not keep a second copy of the class list. A copy
drifts the moment a class is added, and it drifts silently: the new class
passes validation wherever it is minted and is then dropped here, which is the
403-far-from-the-cause that asobi_ops_token:caps/1 exists to avoid.
""".
-spec class_of(term()) -> {ok, class()} | error.
class_of(Term) ->
    case [C || C <- class_names(), C =:= Term] of
        [Class | _] -> {ok, Class};
        [] -> error
    end.

-spec lookup(atom(), [binary()]) -> class() | undefined.
lookup(undefined, _Segments) ->
    undefined;
%% The one route core owns on behalf of extensions. Its class is not in
%% classes/0 because it is per action, declared in the manifest that also
%% declares the handler - so an action reaches its own class or nothing, and
%% "untagged denies" holds unchanged for a method or extension nobody declared.
lookup(Method, [~"ext", Extension, Action]) ->
    case asobi_extensions:ops_action(Extension, Action) of
        #{method := Method, class := Class} -> Class;
        _ -> undefined
    end;
lookup(Method, Segments) ->
    case [Class || {M, S, Class} <- classes(), M =:= Method, matches(S, Segments)] of
        [Class] -> Class;
        _ -> undefined
    end.

%% `'_'` stands for a bound segment (`:id`). It matches one segment and never
%% zero or many, so a tag cannot widen to cover a path the router would not
%% route to the same handler.
-spec matches([segment()], [binary()]) -> boolean().
matches([], []) -> true;
matches(['_' | Pattern], [_ | Segments]) -> matches(Pattern, Segments);
matches([Same | Pattern], [Same | Segments]) -> matches(Pattern, Segments);
matches(_, _) -> false.

-spec method(binary()) -> atom().
method(~"GET") -> get;
method(~"POST") -> post;
method(~"PUT") -> put;
method(~"DELETE") -> delete;
method(_) -> undefined.
