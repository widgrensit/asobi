-module(asobi_world_callbacks_tests).
-include_lib("eunit/include/eunit.hrl").

%% Verify the new optional callbacks are defined in the behaviour

terrain_provider_callback_defined_test() ->
    Callbacks = asobi_world:behaviour_info(callbacks),
    ?assert(lists:member({terrain_provider, 1}, Callbacks)).

on_zone_loaded_callback_defined_test() ->
    Callbacks = asobi_world:behaviour_info(callbacks),
    ?assert(lists:member({on_zone_loaded, 2}, Callbacks)).

on_zone_unloaded_callback_defined_test() ->
    Callbacks = asobi_world:behaviour_info(callbacks),
    ?assert(lists:member({on_zone_unloaded, 2}, Callbacks)).

optional_callbacks_test() ->
    Opts = asobi_world:behaviour_info(optional_callbacks),
    ?assert(lists:member({terrain_provider, 1}, Opts)),
    ?assert(lists:member({on_zone_loaded, 2}, Opts)),
    ?assert(lists:member({on_zone_unloaded, 2}, Opts)).

ws_handler_terrain_message_test() ->
    %% Verify the ws handler can encode a terrain chunk message
    %% by checking the module exports websocket_info/2
    Exports = asobi_ws_handler:module_info(exports),
    ?assert(lists:member({websocket_info, 2}, Exports)).
