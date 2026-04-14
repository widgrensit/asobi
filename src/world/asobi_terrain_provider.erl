-module(asobi_terrain_provider).

%% Behaviour for terrain data providers.
%%
%% Game developers implement this to supply terrain chunk data from
%% files, databases, or procedural generation.

-callback init(Config :: map()) -> {ok, State :: term()}.

-callback load_chunk(Coords :: {integer(), integer()}, State :: term()) ->
    {ok, CompressedBinary :: binary(), NewState :: term()} | {error, term()}.

-callback generate_chunk(Coords :: {integer(), integer()}, Seed :: integer(), State :: term()) ->
    {ok, CompressedBinary :: binary(), NewState :: term()}.

-optional_callbacks([generate_chunk/3]).
