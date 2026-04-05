-module(asobi_group_roles).

%% Role hierarchy and permission checks for groups/guilds.
%%
%% Hierarchy: owner > admin > moderator > member
%% Higher roles can manage lower roles but not equal or higher.

-export([rank/1, can_manage/2, can_kick/2, can_promote/3, can_update_group/1]).
-export([valid_role/1]).

-spec rank(binary()) -> non_neg_integer().
rank(~"owner") -> 100;
rank(~"admin") -> 75;
rank(~"moderator") -> 50;
rank(~"member") -> 0;
rank(_) -> 0.

-spec valid_role(binary()) -> boolean().
valid_role(~"owner") -> true;
valid_role(~"admin") -> true;
valid_role(~"moderator") -> true;
valid_role(~"member") -> true;
valid_role(_) -> false.

-spec can_manage(binary(), binary()) -> boolean().
can_manage(ActorRole, TargetRole) ->
    rank(ActorRole) > rank(TargetRole).

-spec can_kick(binary(), binary()) -> boolean().
can_kick(ActorRole, TargetRole) ->
    rank(ActorRole) >= rank(~"moderator") andalso
        rank(ActorRole) > rank(TargetRole).

-spec can_promote(binary(), binary(), binary()) -> boolean().
can_promote(ActorRole, _TargetCurrentRole, NewRole) ->
    rank(ActorRole) >= rank(~"admin") andalso
        rank(ActorRole) > rank(NewRole) andalso
        NewRole =/= ~"owner".

-spec can_update_group(binary()) -> boolean().
can_update_group(Role) ->
    rank(Role) >= rank(~"admin").
