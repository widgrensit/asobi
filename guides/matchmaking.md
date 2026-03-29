# Matchmaking

Asobi includes a query-based matchmaker that runs as a periodic tick via
the `asobi_matchmaker` gen_server.

## How It Works

1. Player submits a matchmaking ticket with properties and a query
2. Matchmaker ticks periodically (default every 1 second)
3. Each tick groups tickets by mode/region, finds mutually compatible pairs
4. When enough compatible players are found, a match is spawned
5. Players are notified via WebSocket (`matchmaker.matched`)

## Submitting a Ticket

### Via REST

```bash
curl -X POST http://localhost:8080/api/v1/matchmaker \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"},
    "query": "+region:eu-west skill:>=1000 skill:<=1400"
  }'
```

### Via WebSocket

```json
{
  "type": "matchmaker.add",
  "payload": {
    "mode": "arena",
    "properties": {"skill": 1200, "region": "eu-west"},
    "query": "+region:eu-west skill:>=1000 skill:<=1400"
  }
}
```

## Query Language

Tickets include a query that specifies what opponents the player will accept.
Both players must match each other's query for a pairing to form.

```
+region:eu-west mode:ranked skill:>=800 skill:<=1200
```

- `key:value` -- exact match
- `+key:value` -- required (must match)
- `key:>=N` / `key:<=N` -- numeric range
- Multiple conditions are AND-ed

## Skill Window Expansion

When a player waits too long, the matchmaker automatically widens the skill
window. Each tick increments the `expansion_level` for unfilled tickets,
relaxing numeric range constraints.

## Configuration

```erlang
{asobi, [
    {matchmaker, #{
        tick_interval => 1000,       %% ms between matchmaker ticks
        max_wait_seconds => 60       %% max wait before timeout
    }}
]}
```

## Party Support

Players can queue as a party. All party members are placed in the same match:

```json
{
  "type": "matchmaker.add",
  "payload": {
    "mode": "arena",
    "party": ["player_id_2", "player_id_3"],
    "properties": {"skill": 1200},
    "query": "skill:>=1000 skill:<=1400"
  }
}
```

## Cancelling

```json
{"type": "matchmaker.remove", "payload": {"ticket_id": "..."}}
```

Or via REST:

```bash
curl -X DELETE http://localhost:8080/api/v1/matchmaker/<ticket_id> \
  -H 'Authorization: Bearer <token>'
```
