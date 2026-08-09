# Testing with multiple players

Running two clients on one machine is the first thing you do after the
quickstart, and it is where most first sessions go wrong: both windows sign in
as the same player, matchmaking refuses to pair them, and the two views drift
apart.

Nothing is broken. A guest account belongs to the **device**, not to the window.

## Why the second client is the same player

Guest sign-in is create-or-resume on a `{device_id, device_secret}` pair. The
same pair always resumes the same player, which is the whole point: a player who
reinstalls keeps their progress. The SDK helper persists that pair for you:

| SDK | Where the pair is stored |
|-----|--------------------------|
| Defold | `sys.get_save_file("asobi", "guest_device")` |
| Godot | `user://asobi_device.json` |
| JS | `localStorage`, key `asobi.guest_device` |

Two instances of the same project on one machine read the same file, so
`guest_device()` hands both of them the same credentials and the server resumes
one player twice. Two browser tabs on the same origin and profile share
`localStorage` and collapse the same way.

Print `player_id` in both clients after sign-in. If it is the same id, this page
is your problem. If the ids differ, skip to
[Two players, two matches](#two-players-two-matches).

### What one player with two connections looks like

asobi assumes one live connection per player, so the two clients quietly
interfere:

- The matchmaker keeps one live ticket per player and mode. The second queue
  call returns the first client's ticket, and a group that repeats a player is
  rejected, so the two can never be paired with each other.
- Server-to-player messages are addressed by player id and reach **both**
  connections, so each client sees the other's match traffic.
- Closing one client tears down presence for the player the other one is still
  using.

## The quickest fix: a throwaway guest per launch

`generate` mints a pair without persisting it, so every launch is a brand-new
player. Two lines, no storage plumbing, no per-instance setup. This is the right
default for a dev build.

<!-- tabs -->
**Defold**
```lua
local asobi = require("asobi.client")
local device = require("asobi.device")

function init(self)
	local client = asobi.create("localhost", 8084)

	-- Dev only: a fresh pair per launch, never written to disk, so every
	-- instance you start is a different player.
	local device_id, device_secret = device.generate()
	client.auth.guest(client, device_id, device_secret, function(data, err)
		if err then
			print("guest sign-in failed: " .. tostring(err.error))
			return
		end
		print("player_id: " .. data.player_id)
		client.realtime:connect()
	end)
end
```
**Godot**
```gdscript
func _ready() -> void:
	Asobi.host = "localhost"
	Asobi.port = 8084

	# Dev only: a fresh pair per launch, never written to user://, so every
	# instance you start is a different player.
	var creds := AsobiDevice.generate()
	var resp := await Asobi.auth.guest(creds["device_id"], creds["device_secret"])
	if resp.has("error"):
		push_error("guest sign-in failed: %s" % resp.error)
		return
	print("player_id: %s" % resp.player_id)
	Asobi.realtime.connect_to_server()
```
<!-- /tabs -->

Every run leaves another guest account on the node. That is harmless locally,
and `guest_reap_after` clears unclaimed guests on a self-hosted deployment. On
cloud that key is not yours to set, so a test client pointed at a cloud
environment should call `POST /api/v1/players/me/erase`
([REST API](rest-api.md#erasing-your-own-account)) when it shuts down. A crash
still leaks one, so for anything you run repeatedly against cloud prefer
[stable test players](#stable-test-players-across-runs) below, which reuse one
account per instance instead of minting a new one each launch. Ship
`guest_device` in the build players actually install.

## Stable test players across runs

A throwaway guest has no history, so it is no use for testing progression,
leaderboards or an inventory. Give each instance its own storage slot instead
and the same players come back every run.

### Defold

The engine takes `--config=` overrides for any `game.project` key, and Lua reads
them back, which gives you a per-instance slot without touching the code between
runs:

```lua
local slot = sys.get_config_string("asobi.player_slot", "1")

client.auth.guest_device(client, { file = "guest_device_" .. slot }, function(data, err)
	if err then
		print("guest sign-in failed: " .. tostring(err.error))
		return
	end
	print("slot " .. slot .. " is " .. data.player_id)
end)
```

The editor's Build runs one instance, so bundle the game once (Project >
Bundle) and launch the executable twice:

```bash
./MyGame &                                # slot 1
./MyGame --config=asobi.player_slot=2 &   # slot 2
```

### Godot

Godot can launch several instances itself. Open Debug > Customize Run
Instances..., raise the instance count, and give each instance its own Launch
Arguments (`-- player=2` for the second one). Arguments after `--` come back
from `OS.get_cmdline_user_args()`:

```gdscript
func _player_slot() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("player="):
			return arg.trim_prefix("player=")
	return "1"

func _ready() -> void:
	var slot := _player_slot()
	var resp := await Asobi.auth.guest_device({"path": "user://asobi_device_%s.json" % slot})
	if resp.has("error"):
		push_error("guest sign-in failed: %s" % resp.error)
		return
	print("slot %s is %s" % [slot, resp.player_id])
```

To swap players inside a running client instead, call the SDK's `clear` and sign
in again: the next `guest_device` mints a new guest and returns `created = true`.
`clear` is local only and does not delete the account on the server.

## Two players, two matches

Distinct players can still land in separate matches. In order of how often it
happens:

- **Bots got there first.** The bot spawner checks every 8 seconds and tops each
  mode up to its target, so one human waiting more than 8 seconds is matched
  with a bot, and the second human then gets a match of their own. Drop the
  `bots` line from the match script while testing human against human. See
  [Lua bots](lua-bots.md).
- **Different modes.** Tickets are grouped per mode, and a typo in the mode
  string is two queues of one.
- **`match_size = 1`.** Every ticket spawns its own match by definition.
- **`match_size` above the number of clients you are running.** The tickets wait
  until `max_wait_seconds` expires them.

## Checklist

1. Print `player_id` in every client. Different ids, or nothing else here
   matters.
2. Use `generate` in dev builds, or one storage slot per instance.
3. Turn bots off while you are testing that two humans pair.
4. Queue both clients for the same mode, within a few seconds of each other.

See [Authentication](authentication.md#guest-anonymous) for the guest contract
itself, and [Matchmaking](matchmaking.md) for ticket and strategy behaviour.
