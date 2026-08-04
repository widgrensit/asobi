-module(asobi_ops_caps).
-moduledoc """
Capability classes for the ops plane, and the table that tags every route with
exactly one of them (ADR 0007).

`read` is everything non-mutating, `player_data` is ban, grant, broadcast and
roster edits, `config` is economy definitions, credentials and deploy-adjacent
settings. The only authorisation decision anywhere in the plane is membership
of a route's class in the actor's `caps`.

Role names are deliberately absent. They are not stable wire surface -
capability classes are, and adding a fourth class later is additive.
`asobi_saas` maps its own roles onto these classes once, at token-mint time,
so the string "owner" never reaches this plane.

A route with no entry in `classes/0` has no class and `authorised/2` denies
it, so an untagged or mis-mounted route is closed rather than open.
""".

-export([classes/0, class/2, authorised/2]).

-type class() :: read | player_data | config.
-type route() :: {atom(), [binary()], class()}.

-export_type([class/0, route/0]).

-doc """
The route table: method, path segments below `/api/v1/ops`, and class.

A router meta-test holds this table and the router's ops group to each other,
so a new ops route cannot ship untagged.
""".
-spec classes() -> [route()].
classes() ->
    [
        {get, [~"players"], read},
        {get, [~"matches"], read},
        {get, [~"features"], read}
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

-spec lookup(atom(), [binary()]) -> class() | undefined.
lookup(undefined, _Segments) ->
    undefined;
lookup(Method, Segments) ->
    case [Class || {M, S, Class} <- classes(), M =:= Method, S =:= Segments] of
        [Class] -> Class;
        _ -> undefined
    end.

-spec method(binary()) -> atom().
method(~"GET") -> get;
method(~"POST") -> post;
method(~"PUT") -> put;
method(~"DELETE") -> delete;
method(_) -> undefined.
