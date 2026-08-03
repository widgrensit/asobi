%% Ceiling on the bot-fill target (min_players/max_players), enforced both
%% at Lua config-load time (asobi_lua_config) and at spawn time
%% (asobi_bot_spawner, which also covers sys.config-declared game modes
%% that bypass the Lua-side check). Bounds worst-case matchmaker load and
%% allocation from a single game-config value; see #79 follow-up (HIGH
%% severity DoS fix).
-define(MAX_BOT_FILL, 64).
