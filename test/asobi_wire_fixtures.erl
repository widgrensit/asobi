-module(asobi_wire_fixtures).
-moduledoc """
The canonical binary `world.tick` corpus, and the guard that keeps it honest.

Seven SDKs each carry their own decoder for this wire, written in seven
languages, and none of them can call `asobi_wire:decode/1` to check itself. The
corpus is what they check against instead: committed bytes produced by the real
encoder, paired with a manifest that says in plain JSON what those bytes mean.
An SDK test decodes the `.bin` and asserts it gets the manifest's frame.

`generate/0` writes the corpus; `check/0` asserts the committed bytes still match
what the encoder produces today and runs in CI. That pairing is the point. A
codec change that nobody propagated to the SDKs fails `check/0` loudly here,
rather than silently in a game six weeks later - which is exactly how the deleted
`asobi_ws_binary` was allowed to rot, having had no fixtures at all.

Regenerating is therefore a deliberate act with consequences: if `check/0` fails
and the change was intended, run `generate/0`, commit the new bytes, and update
every SDK decoder in the same change.
""".

-export([generate/0, check/0, dir/0, path/1, frames/0]).

-doc "Writes every fixture and the manifest. Run after an intended codec change.".
-spec generate() -> ok.
generate() ->
    Dir = dir(),
    ok = filelib:ensure_path(Dir),
    Manifest = [
        begin
            {ok, Bin} = asobi_wire:encode(Frame),
            ok = file:write_file(fixture_path(Dir, Name), Bin),
            #{~"name" => Name, ~"bytes" => byte_size(Bin), ~"frame" => to_json(Frame)}
        end
     || {Name, Frame} <- frames()
    ],
    file:write_file(
        filename:join(Dir, "manifest.json"),
        iolist_to_binary(json:format(Manifest))
    ).

-doc """
Every fixture, encoded fresh and compared byte-for-byte with what is committed.

Returns the failures rather than raising, so the caller decides whether a
mismatch is a test failure or a prompt to regenerate.
""".
-spec check() -> {ok, non_neg_integer()} | {error, [binary()]}.
check() ->
    Bad = [
        Name
     || {Name, Frame} <- frames(),
        begin
            {ok, Fresh} = asobi_wire:encode(Frame),
            case file:read_file(fixture_path(dir(), Name)) of
                {ok, Fresh} -> false;
                _ -> true
            end
        end
    ],
    case Bad of
        [] -> {ok, length(frames())};
        _ -> {error, Bad}
    end.

-doc "The committed bytes for one fixture.".
-spec path(binary()) -> file:filename_all().
path(Name) -> fixture_path(dir(), Name).

-doc "Where the corpus lives, resolved from the app's priv dir so it ships.".
-spec dir() -> file:filename_all().
dir() ->
    filename:join([code:lib_dir(asobi), "priv", "wire_fixtures"]).

-doc """
The corpus itself.

Chosen to pin the decisions an SDK author gets wrong, not to be exhaustive: one
case per property that would otherwise fail silently on a client.
""".
-spec frames() -> [{binary(), asobi_wire:frame()}].
frames() ->
    [
        %% An add is the only record carrying an entity id, so this is the frame
        %% that establishes a slot binding. An SDK that skips the id field here
        %% reads every subsequent record misaligned.
        {~"add_with_all_value_types", #{
            kind => sequenced,
            zone => {0, 0},
            frame_seq => 1,
            kf => false,
            tick => 20,
            records => [
                #{
                    op => add,
                    slot => 7,
                    gen => 0,
                    id => ~"01a0115f-547e-714f-829f-408c855ab77b",
                    fields => #{
                        ~"x" => 12.5,
                        ~"y" => -3.25,
                        ~"hp" => 100,
                        ~"alive" => true,
                        ~"stunned" => false,
                        ~"name" => ~"player one",
                        ~"target" => null
                    }
                }
            ]
        }},
        %% The steady state, and the frame the whole design is sized around: it
        %% has to fit one datagram.
        {~"steady_state_40_updates", #{
            kind => sequenced,
            zone => {3, -2},
            frame_seq => 4711,
            kf => false,
            tick => 94220,
            records => [
                #{
                    op => update,
                    slot => I,
                    gen => 0,
                    fields => #{
                        ~"x" => I * 1.5, ~"y" => I * -0.25, ~"vx" => 0.5, ~"vy" => -0.5
                    }
                }
             || I <- lists:seq(1, 40)
            ]
        }},
        %% A keyframe is all-adds by construction (ADR 0011, decision 3), which is
        %% what makes resync re-establish every binding for free.
        {~"keyframe_all_adds", #{
            kind => sequenced,
            zone => {-1, -1},
            frame_seq => 88,
            kf => true,
            tick => 0,
            records => [
                #{
                    op => add,
                    slot => I,
                    %% A different generation per record, so a decoder that reads
                    %% the byte at the wrong offset cannot pass by accident.
                    gen => I,
                    id => iolist_to_binary(
                        io_lib:format("0000000~2..0b-0000-7000-8000-000000000000", [I])
                    ),
                    fields => #{~"x" => I + 0.0, ~"y" => 0.0}
                }
             || I <- lists:seq(1, 5)
            ]
        }},
        %% Removes carry the slot alone. An SDK expecting an id here desyncs.
        {~"removes_only", #{
            kind => sequenced,
            zone => {0, 0},
            frame_seq => 12,
            kf => false,
            tick => 240,
            records => [#{op => remove, slot => S, gen => 7} || S <- [1, 2, 65535]]
        }},
        %% The leave mirror, and the one frame a client must apply WITHOUT the
        %% sequence check. An SDK that gates it on frame_seq keeps ghosts forever.
        {~"ungated_leave_removals", #{
            kind => ungated,
            zone => {5, 5},
            frame_seq => 0,
            kf => false,
            tick => 0,
            records => [#{op => remove, slot => S, gen => 255} || S <- [3, 9]]
        }},
        %% An empty zone still has a sequence position. A decoder that treats zero
        %% records as an error rejects a legitimate baseline.
        {~"empty_keyframe", #{
            kind => sequenced,
            zone => {0, 0},
            frame_seq => 0,
            kf => true,
            tick => 0,
            records => []
        }},
        %% Coordinates run negative and the sequence is a 53-bit counter; both are
        %% places a decoder using the wrong width or signedness looks fine until it
        %% does not.
        {~"extremes", #{
            kind => sequenced,
            zone => {-2147483648, 2147483647},
            frame_seq => 16#1FFFFFFFFFFFFF,
            kf => false,
            tick => 16#1FFFFFFFFFFFFF,
            records => [#{op => update, slot => 0, gen => 255, fields => #{~"x" => 0.0}}]
        }}
    ].

%% --- Internal ---

fixture_path(Dir, Name) -> filename:join(Dir, <<Name/binary, ".bin">>).

%% The manifest is read by seven runtimes, so it is plain JSON with no
%% Erlang-shaped cleverness: atoms become strings, the zone becomes a pair.
to_json(#{kind := Kind, zone := {ZX, ZY}} = F) ->
    #{
        ~"kind" => atom_to_binary(Kind),
        ~"zone" => [ZX, ZY],
        ~"frame_seq" => maps:get(frame_seq, F),
        ~"kf" => maps:get(kf, F),
        ~"tick" => maps:get(tick, F),
        ~"records" => [record_json(R) || R <- maps:get(records, F)]
    }.

record_json(#{op := Op, slot := Slot, gen := Gen} = R) ->
    Base = #{~"op" => atom_to_binary(Op), ~"slot" => Slot, ~"gen" => Gen},
    Base1 =
        case R of
            #{id := Id} -> Base#{~"id" => Id};
            _ -> Base
        end,
    case maps:get(fields, R, #{}) of
        Empty when map_size(Empty) =:= 0 -> Base1;
        Fields -> Base1#{~"fields" => Fields}
    end.
