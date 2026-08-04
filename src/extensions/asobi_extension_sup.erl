-module(asobi_extension_sup).
-moduledoc """
One supervisor per extension, under one supervisor for the lot.

```
asobi_sup  (one_for_one, 10/60)
  |- ...core children...
  `- asobi_extension_sup       (one_for_one, 3/60)
       |- quests               (transient, own intensity)
       |- clans                (transient, own intensity)
       `- asobi_extension_watch
```

The reason `sup/0` is a contract key at all, rather than extensions being
plain OTP applications with their own `mod`, is that applications in a release
are **permanent** by default, and in OTP a permanent application terminating
takes the whole runtime with it. An extension supervising itself and
exceeding its restart intensity therefore kills matchmaking, presence and
every live match. This is the ordinary BEAM pattern rather than an invention:
Ecto repos, Oban and Phoenix endpoints are all started in the host's tree.

Three deliberate choices:

- **`one_for_one` at both levels.** Extensions are independent by
  construction: they share only `asobi_repo`, and the wire seam between them
  is RPC. One restarting is never a reason to restart another.
- **Each extension's sub-supervisor is `transient`.** Exceeding a restart
  intensity makes a supervisor exit with reason `shutdown`, which a transient
  child is not restarted for. So an extension that has burned its own budget
  goes dark and stays dark, attributed by name, instead of escalating.
  Restarting it here would only relay the same crash loop upwards until it
  reached `asobi_sup` and took the node with it, which is the exact outcome
  this tree exists to prevent. Transient rather than temporary because a
  sub-supervisor killed for any *other* abnormal reason is a core-side fault,
  not an extension giving up, and should be restarted.
- **Intensity 3 in 60 here.** Extension failures never consume it: a
  transient child exiting `shutdown` is not a restart. The budget covers
  `asobi_extension_watch` only, so nothing an extension does can exhaust it.

Per-extension intensity defaults to 5 in 60 and is settable with
`{extension_restart, #{intensity => I, period => P}}` in asobi's app env.

## Readiness is a precondition, not a race

An extension child that queries at `init/1` needs the pool up and its own
tables created, and must not crash if they are not - a crash loop here ends
with the extension dark and staying dark, which is exactly the outcome the
transient sub-supervisor is for. Rather than making every extension carry a
retry path, a loaded-marker and a fallback, core makes the precondition hold.

`asobi_app:start/2` runs `kura_migrator:migrate/1` and then
`asobi_readiness:mark_ready/0` **before** `asobi_sup:start_link/0`, so by the
time this supervisor initialises the answer is already final and cannot flip
later. If it is `false`, migrations did not complete: no extension starts and
one line says which ones. `asobi_readiness:guard/0` is the other half of the
same marker, and answers 503 on the dispatch path for the same reason.

The extension is dark either way. The difference is that it is dark for a
stated reason instead of after burning its restart budget, and that `init/1`
gets to assume a working database.
""".

-behaviour(supervisor).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0, running/0]).
-export([init/1]).

-spec start_link() -> supervisor:startlink_ret().
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-doc "The extensions whose sub-supervisor is alive. An installed name missing here has gone dark.".
-spec running() -> [asobi_extension:name()].
running() ->
    [
        Id
     || {Id, Pid, _Type, _Modules} <- supervisor:which_children(?MODULE),
        is_pid(Pid),
        Id =/= asobi_extension_watch
    ].

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 3, period => 60},
    {ok, {SupFlags, children(asobi_extensions:resolve())}}.

%% With no extensions installed this is one idle supervisor process: no
%% children, no timers, no tables, and nothing on any request path.
children([]) ->
    [];
children(Extensions) ->
    case asobi_readiness:ready() of
        true -> [sub_sup(Extension) || Extension <- Extensions] ++ [watch(Extensions)];
        false -> none_started(Extensions)
    end.

%% No watch child either: it exists to say which extension went dark, and
%% saying it twice about the same set is noise.
none_started(Extensions) ->
    ?LOG_ERROR(#{
        msg => ~"extensions_not_started",
        extensions => [Name || #{name := Name} <- Extensions],
        detail => ~"migrations did not complete; extensions answer 503, core is unaffected"
    }),
    [].

sub_sup(#{name := Name, module := Module}) ->
    #{
        id => Name,
        start => {asobi_extension_child_sup, start_link, [Name, Module]},
        restart => transient,
        shutdown => infinity,
        type => supervisor
    }.

%% Started last, so every sub-supervisor it monitors already exists.
watch(Extensions) ->
    #{
        id => asobi_extension_watch,
        start => {asobi_extension_watch, start_link, [[N || #{name := N} <- Extensions]]},
        restart => permanent,
        shutdown => 5000,
        type => worker
    }.
