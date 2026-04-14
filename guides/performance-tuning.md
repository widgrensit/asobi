# Performance Tuning

Optimisation features for high-throughput world servers. These are all
opt-in and backward compatible -- existing configurations work unchanged.

## Spatial Grid Index

By default, spatial queries (`query_radius`, `query_rect`) scan all
entities in a zone via `maps:fold` -- O(n). For zones with many entities,
enable the cell-based spatial grid for O(1) cell lookup + local scan.

```erlang
Config = #{
    game_module => my_world,
    spatial_grid_cell_size => 16  %% units per cell
}.
```

The grid is maintained automatically as entities are added, removed, or
moved during ticks. Query through the zone API:

```erlang
Results = asobi_zone:query_radius(ZonePid, {100.0, 200.0}, 50.0).
%% Returns [{EntityId, {X, Y}}, ...]
```

When no `spatial_grid_cell_size` is configured, the zone falls back to
the brute-force scan (existing behaviour).

### Cell Size Guidelines

| Entity Density | Recommended Cell Size |
|---------------|----------------------|
| Sparse (< 50/zone) | Don't enable (overhead not worth it) |
| Medium (50-200/zone) | 32-64 units |
| Dense (200+/zone) | 8-16 units |

## Broadcast Batching

Zone deltas are JSON-encoded once and the pre-encoded binary is sent to
all subscribers. This replaces N `json:encode` calls with exactly 1.

This is automatic -- no configuration needed. Subscribers receive
`zone_delta_raw` messages containing pre-encoded JSON, which the
WebSocket handler forwards directly without re-encoding.

## Adaptive Tick Rates

Zones with no subscribers tick at a reduced rate to save CPU:

```erlang
Config = #{
    cold_tick_divisor => 10  %% cold zones tick 10x less often (default)
}.
```

| Zone State | Tick Rate | When |
|-----------|-----------|------|
| Hot | Full (every tick) | Has subscribers |
| Cold | 1/N (every Nth tick) | Entities but no subscribers |
| Empty | Not ticked | No entities, no subscribers |

The ticker provides manual controls:

```erlang
asobi_world_ticker:promote_zone(TickerPid, ZonePid).  %% → hot
asobi_world_ticker:demote_zone(TickerPid, ZonePid).   %% → cold
asobi_world_ticker:remove_zone(TickerPid, ZonePid).   %% → stop ticking
```

Zone promotion/demotion is typically handled automatically by the zone
manager based on subscriber presence.

## Binary Protocol

For maximum throughput, clients can negotiate binary WebSocket frames
instead of JSON. Set `binary_protocol: true` in the `session.connect`
payload.

Binary frames use a Tag-Length-Value format:

```
[type:u8][length:u32be][payload:bytes]
```

### Message Types

| Tag | Type | Payload |
|-----|------|---------|
| 0x01 | Terrain chunk | coords (2x i32) + compressed data |
| 0x02 | Entity deltas | tick (u64) + counted delta list |
| 0x03 | Match state | Reserved |

### Size Savings

Terrain chunks save ~25% vs JSON+base64 encoding. Entity deltas save
varies based on field count but typically 15-30%.

Use `asobi_ws_binary` for encoding/decoding:

```erlang
Bin = asobi_ws_binary:encode_terrain_chunk({5, 10}, CompressedData).
{{5, 10}, Data} = asobi_ws_binary:decode_terrain_chunk(Bin).
```

JSON remains the default protocol. Binary is opt-in per connection.
