-module(asobi_console).
-moduledoc """
The operator console bundle: what `priv/console` holds, resolved once.

The console is a Vite/React bundle built from `console/` and committed to
`priv/console`. This application serves it from the same origin as the ops
API it reads - one artefact, no second host and no second container.

A host that has extensions with their own console screens builds a **composed**
bundle instead - `rebar3 asobi console`, which compiles every installed
extension's `priv/console` into one chunk alongside core's own screens - and
points `console_bundle_app` at the application that bundle was written into.
Nothing below changes for it: the composed bundle is read, validated and served
by exactly this code, because it is the same shape of Vite output. See
`guides/console-extensions.md`.

**Nothing here joins a request path onto a directory.** The served set is
derived from the build manifest - the entry chunk, its stylesheets, and the
assets it references - and each file is read into a map keyed by its own
basename before the first request is answered. A request names a key that is
in the map or gets a 404, so there is no traversal primitive to get wrong.
That is worth the indirection: `nova_file_controller:get_dir/1` joins wildcard
path segments with no dot-segment check, and this is the shape that has no
wildcard to join.

Manifest paths are validated even though the build writes them. A bundler is
a third-party program producing a file this module then reads off disk; a
name with a slash or a dot segment in it is refused rather than resolved.

The console is **off unless `console` is set true** in the `asobi` application
env. Nova starts one listener, so the console shares the game port, and an
operator surface appearing on a public port has to be asked for rather than
arriving with an upgrade. With no `ops_secret` configured it can be loaded and
cannot be used - there is no default credential (`m:asobi_ops_auth`).

Both outcomes of the load are memoised, the failure included. A node whose
bundle is missing says so once and then answers 503 from a term, rather than
stat-ing an absent directory on every request.
""".

-include_lib("kernel/include/logger.hrl").

-export([enabled/0, bundle/0, asset/1, load/1]).
-ifdef(TEST).
-export([reset/0]).
-endif.

-define(KEY, {?MODULE, bundle}).
-define(DIR, "console").
-define(MANIFEST, "manifest.json").

-type asset() :: #{body := binary(), mime := binary(), etag := binary()}.
-type bundle() :: #{
    script := binary(),
    styles := [binary()],
    assets := #{binary() => asset()}
}.
-type problem() ::
    {bundle_app_unavailable, term()}
    | {manifest_unreadable, term()}
    | {manifest_not_json, term()}
    | no_entry
    | {bad_asset_name, binary()}
    | {unknown_asset_type, binary()}
    | {asset_unreadable, binary(), term()}.

-export_type([asset/0, bundle/0, problem/0]).

%% Closed set. An extension the build starts emitting is a deliberate change
%% here, not a file that quietly acquires `application/octet-stream`.
-define(MIME, [
    {~".js", ~"text/javascript; charset=utf-8"},
    {~".css", ~"text/css; charset=utf-8"},
    {~".svg", ~"image/svg+xml"},
    {~".png", ~"image/png"},
    {~".webp", ~"image/webp"},
    {~".woff2", ~"font/woff2"}
]).

-doc """
Whether this node serves the console.

Default `false`. See the module doc for why it is not `true`.
""".
-spec enabled() -> boolean().
enabled() ->
    application:get_env(asobi, console, false) =:= true.

-doc "The resolved bundle, memoised across both outcomes.".
-spec bundle() -> {ok, bundle()} | {error, problem()}.
bundle() ->
    case persistent_term:get(?KEY, undefined) of
        undefined ->
            Result = resolve(),
            log(Result),
            persistent_term:put(?KEY, Result),
            Result;
        Result ->
            narrow_bundle(Result)
    end.

%% persistent_term:get/2 answers persistent_term:value(). What went in is
%% resolve/0's own result, put one clause up, so this is a boundary rather than
%% a shape worth re-deriving. See docs/eqwalizer-idioms.md.
-spec narrow_bundle(dynamic()) -> {ok, bundle()} | {error, problem()}.
narrow_bundle({ok, #{script := _, styles := _, assets := _}} = Ok) -> Ok;
narrow_bundle({error, _} = Error) -> Error.

-doc """
One asset by basename, or `error` for anything not in the bundle.

The lookup is a map read. `Name` is never used to build a path.
""".
-spec asset(binary()) -> {ok, asset()} | error.
asset(Name) when is_binary(Name) ->
    case bundle() of
        {ok, #{assets := Assets}} -> maps:find(Name, Assets);
        {error, _} -> error
    end;
asset(_Name) ->
    error.

-doc """
Read a console bundle out of `Dir`.

Pure apart from the reads, so a test can point it at a directory it built
itself and check what the hardening refuses.
""".
-spec load(file:filename_all()) -> {ok, bundle()} | {error, problem()}.
load(Dir) ->
    maybe
        {ok, Raw} ?= read_manifest(Dir),
        {ok, Manifest} ?= decode(Raw),
        {ok, Entry} ?= entry(Manifest),
        {ok, Script} ?= name(maps:get(~"file", Entry, undefined)),
        {ok, Served} ?= names(declared(Manifest)),
        {ok, Assets} ?= read_assets(Dir, Served),
        {ok, #{script => Script, styles => stylesheets(Served), assets => Assets}}
    else
        %% Behaviour-identical to the implicit short circuit - every `?=` above
        %% answers `{ok, _} | {error, problem()}`, so this is the only shape
        %% that can reach here. Written out because eqwalizer cannot type a
        %% `maybe` block without it.
        {error, _} = Error -> Error
    end.

%% Everything the manifest names, and nothing else. Deriving the served set
%% from the build's own output rather than from a directory listing means a
%% stray file that lands in `priv/console` is not reachable, and a name is
%% only ever a map key.
%% [term()], deliberately: names/1 is what refuses a manifest value that is not
%% a string, and it can only do that if the value reaches it. Re-narrowing here
%% would drop the bad value silently and load a console missing a screen.
-spec declared(map()) -> [term()].
declared(Manifest) ->
    lists:usort(
        lists:append([
            [
                maps:get(~"file", Chunk)
             || Chunk <- maps:values(Manifest), is_map_key(~"file", Chunk)
            ],
            collect(~"css", Manifest),
            collect(~"assets", Manifest)
        ])
    ).

-spec collect(binary(), map()) -> [term()].
collect(Key, Manifest) ->
    lists:append([maps:get(Key, Chunk, []) || Chunk <- maps:values(Manifest), is_map(Chunk)]).

-spec binaries([term()]) -> [binary()].
binaries(L) -> [B || B <- L, is_binary(B)].

%% Which of the served names are stylesheets the shell has to link. Vite emits
%% the entry's CSS as its own manifest chunk when code splitting is off, so
%% reading the entry's `css` key alone silently produces an unstyled console.
-spec stylesheets([binary()]) -> [binary()].
stylesheets(Names) ->
    [Name || Name <- Names, filename:extension(Name) =:= ~".css"].

-spec resolve() -> {ok, bundle()} | {error, problem()}.
resolve() ->
    case dir() of
        {ok, Dir} -> load(Dir);
        {error, _} = Error -> Error
    end.

%% Which application's `priv/console` is served. `asobi` unless a host composed
%% its own bundle with `rebar3 asobi console`, which writes the built bundle
%% into an application of the host's own and needs this pointed at it.
%%
%% A configured application that is not in the release is a refusal, not a
%% fallback to asobi's own bundle. A host that asked for its composed console
%% and silently got the stock one would be missing exactly the screens it built
%% the thing for, with nothing saying so - the same reasoning that makes an
%% unreadable `ops_secret_file` leave the secret unset rather than fall back to
%% the environment variable.
-spec dir() -> {ok, file:filename_all()} | {error, problem()}.
dir() ->
    priv_dir(application:get_env(asobi, console_bundle_app, asobi)).

%% An application name is an atom. Anything else - a binary out of a
%% container's environment, a string out of a hand-written sys.config - is
%% refused here rather than reaching `code:priv_dir/1`, so a mistyped value is
%% the same legible 503 as a missing application instead of a crash inside a
%% request.
-spec priv_dir(term()) -> {ok, file:filename_all()} | {error, problem()}.
priv_dir(App) when is_atom(App) ->
    case code:priv_dir(App) of
        {error, _Reason} -> {error, {bundle_app_unavailable, App}};
        Priv -> {ok, filename:join(Priv, ?DIR)}
    end;
priv_dir(App) ->
    {error, {bundle_app_unavailable, App}}.

-spec read_manifest(file:filename_all()) -> {ok, binary()} | {error, problem()}.
read_manifest(Dir) ->
    case file:read_file(filename:join(Dir, ?MANIFEST)) of
        {ok, Raw} -> {ok, Raw};
        {error, Reason} -> {error, {manifest_unreadable, Reason}}
    end.

-spec decode(binary()) -> {ok, map()} | {error, problem()}.
decode(Raw) ->
    try json:decode(Raw) of
        Manifest when is_map(Manifest) -> {ok, Manifest};
        Other -> {error, {manifest_not_json, Other}}
    catch
        _:Reason -> {error, {manifest_not_json, Reason}}
    end.

%% Vite keys the manifest by source path and flags exactly one entry. Reading
%% the flag rather than a hardcoded key means renaming the entry source does
%% not silently produce a bundle with no script in it.
-spec entry(map()) -> {ok, map()} | {error, problem()}.
entry(Manifest) ->
    case [Chunk || Chunk <- maps:values(Manifest), is_entry(Chunk)] of
        [Entry] -> {ok, Entry};
        _ -> {error, no_entry}
    end.

-spec is_entry(term()) -> boolean().
is_entry(#{~"isEntry" := true}) -> true;
is_entry(_Chunk) -> false.

-spec names([term()]) -> {ok, [binary()]} | {error, problem()}.
names(Paths) ->
    names(Paths, []).

%% Explicit recursion: see docs/eqwalizer-idioms.md. Order is preserved, as
%% lists:foldr/3 did.
-spec names([term()], [binary()]) -> {ok, [binary()]} | {error, problem()}.
names([], Acc) ->
    {ok, binaries(lists:reverse(Acc))};
names([Path | Rest], Acc) ->
    case name(Path) of
        {ok, Name} -> names(Rest, [Name | Acc]);
        {error, _} = Error -> Error
    end.

%% The one place a manifest string becomes a key. Everything about the value
%% is checked here: it must sit directly under `assets/`, and the basename
%% must be an ordinary content-hashed filename - no separator, no dot segment,
%% nothing that means something to a filesystem.
-spec name(term()) -> {ok, binary()} | {error, problem()}.
name(<<"assets/", Name/binary>> = Path) ->
    case safe_name(Name) andalso mime(Name) =/= error of
        true -> {ok, Name};
        false -> refuse(Name, Path)
    end;
name(Path) when is_binary(Path) ->
    {error, {bad_asset_name, Path}};
name(Path) ->
    {error, {bad_asset_name, iolist_to_binary(io_lib:format("~p", [Path]))}}.

-spec refuse(binary(), binary()) -> {error, problem()}.
refuse(Name, Path) ->
    case safe_name(Name) of
        true -> {error, {unknown_asset_type, Path}};
        false -> {error, {bad_asset_name, Path}}
    end.

-spec safe_name(binary()) -> boolean().
safe_name(Name) when byte_size(Name) > 0, byte_size(Name) =< 128 ->
    binary:match(Name, ~"..") =:= nomatch andalso
        binary:first(Name) =/= $. andalso
        lists:all(fun is_name_char/1, binary_to_list(Name));
safe_name(_Name) ->
    false.

-spec is_name_char(term()) -> boolean().
is_name_char(Char) when Char >= $a, Char =< $z -> true;
is_name_char(Char) when Char >= $A, Char =< $Z -> true;
is_name_char(Char) when Char >= $0, Char =< $9 -> true;
is_name_char($.) -> true;
is_name_char($-) -> true;
is_name_char($_) -> true;
is_name_char(_Char) -> false.

-spec mime(binary()) -> binary() | error.
mime(Name) ->
    Ext = string:lowercase(filename:extension(Name)),
    case [M || {E, M} <- ?MIME, E =:= Ext, is_binary(M)] of
        [Mime | _] -> Mime;
        [] -> error
    end.

-spec read_assets(file:filename_all(), [binary()]) ->
    {ok, #{binary() => asset()}} | {error, problem()}.
read_assets(Dir, Names) ->
    read_assets(Dir, Names, #{}).

%% Explicit recursion: see docs/eqwalizer-idioms.md.
-spec read_assets(file:filename_all(), [binary()], #{binary() => asset()}) ->
    {ok, #{binary() => asset()}} | {error, problem()}.
read_assets(_Dir, [], Acc) ->
    {ok, Acc};
read_assets(Dir, [Name | Rest], Acc) ->
    case read_asset(Dir, Name, Acc) of
        {ok, Next} -> read_assets(Dir, Rest, Next);
        {error, _} = Error -> Error
    end.

%% Takes the accumulator itself rather than a `{ok, _} | {error, _}`: the fold
%% this replaced threaded the error through every remaining element, and
%% read_assets/3 short-circuits instead. Dialyzer caught the leftover clause.
-spec read_asset(file:filename_all(), binary(), #{binary() => asset()}) ->
    {ok, #{binary() => asset()}} | {error, problem()}.
read_asset(Dir, Name, Acc) ->
    Path = filename:join([Dir, ~"assets", Name]),
    case file:read_file(Path) of
        {ok, Body} ->
            %% name/1 already refuses a name whose extension has no mime, so
            %% this restates an invariant rather than adding a check. Worth
            %% restating: asset()'s mime is a binary, and the controller puts
            %% it straight into a content-type header, so the atom `error`
            %% reaching here would be a malformed response rather than a crash.
            case mime(Name) of
                Mime when is_binary(Mime) ->
                    {ok, Acc#{Name => #{body => Body, mime => Mime, etag => etag(Body)}}};
                error ->
                    %% Unreachable: name/1 refuses a name whose extension has
                    %% no mime, on the same basename this re-derives. Raised
                    %% rather than returned so it does not read as an outcome
                    %% callers should expect from problem().
                    error({unreachable, {no_mime, Name}})
            end;
        {error, Reason} ->
            {error, {asset_unreadable, Name, Reason}}
    end.

%% A strong ETag over the bytes. The filename already carries a content hash,
%% so this only matters for the one case the hash cannot cover: the same
%% filename served by a node whose bundle was replaced underneath it.
-spec etag(binary()) -> binary().
etag(Body) ->
    Hex = binary:encode_hex(binary:part(crypto:hash(sha256, Body), 0, 16), lowercase),
    <<$", Hex/binary, $">>.

-spec log({ok, bundle()} | {error, problem()}) -> ok.
log({ok, #{script := Script, assets := Assets}}) ->
    ?LOG_INFO(#{
        msg => ~"console bundle loaded",
        script => Script,
        assets => map_size(Assets)
    }),
    ok;
log({error, Problem}) ->
    ?LOG_WARNING(#{
        msg => ~"console bundle unavailable; /console answers 503",
        problem => Problem
    }),
    ok.

-ifdef(TEST).
-spec reset() -> ok.
reset() ->
    _ = persistent_term:erase(?KEY),
    ok.
-endif.
