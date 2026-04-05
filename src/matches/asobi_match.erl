-module(asobi_match).

%% Behaviour that game developers implement to define their game logic.
%%
%% Example:
%%   -module(my_card_game).
%%   -behaviour(asobi_match).
%%   -export([init/1, join/2, leave/2, handle_input/3, tick/1, get_state/2]).
%%
%%   init(Config) -> {ok, #{deck => shuffle(Config), players => #{}}}.
%%   join(PlayerId, State) -> {ok, State#{players => ...}}.
%%   tick(State) -> {ok, State}.  %% or {finished, Result, State}

-callback init(Config :: map()) ->
    {ok, GameState :: term()}.

-callback join(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-callback leave(PlayerId :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback handle_input(PlayerId :: binary(), Input :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()} | {error, Reason :: term()}.

-callback tick(GameState :: term()) ->
    {ok, GameState1 :: term()}
    | {finished, Result :: map(), GameState1 :: term()}.

-callback get_state(PlayerId :: binary(), GameState :: term()) ->
    StateForPlayer :: map().

-callback vote_requested(GameState :: term()) ->
    {ok, VoteConfig :: map()} | none.

-callback vote_resolved(Template :: binary(), Result :: map(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback phases(Config :: map()) -> [asobi_phase:phase_def()].

-callback on_phase_started(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-callback on_phase_ended(PhaseName :: binary(), GameState :: term()) ->
    {ok, GameState1 :: term()}.

-optional_callbacks([
    tick/1,
    vote_requested/1,
    vote_resolved/3,
    phases/1,
    on_phase_started/2,
    on_phase_ended/2
]).
