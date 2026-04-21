# Recording the hot-reload video

Target: **15-second MP4** for the `asobi` and `asobi_lua` READMEs + the
landing page.

## Setup

1. `docker compose up -d` — starts Postgres, asobi, and an nginx proxy.
2. Open <http://localhost:3000> in a browser, sized to a clean 16:9
   (1280×720 is a good target — set the browser window to that size
   before recording).
3. Open `lua/match.lua` in your editor. Arrange the editor and browser
   side-by-side so both are visible in the recording frame.

## Shot list (15 seconds)

| t    | Frame                                                   |
| ---- | ------------------------------------------------------- |
| 0.0s | Browser only, red cube on dark background, `message: "Hello from Lua!"` visible |
| 2.0s | Cut to split-screen — editor on the left, browser on the right |
| 3.0s | Cursor moves to `cube_color = "#ff4757"` line           |
| 4.0s | Edit to `cube_color = "#4facfe"` — save (Ctrl-S)        |
| 4.5s | Browser: cube flashes blue. No reload icon, no disconnect |
| 6.0s | Cursor moves to `message` line                           |
| 7.0s | Edit to `message = "edit · save · ship"` — save          |
| 8.0s | Browser: banner text changes                             |
| 10s  | Cursor moves to `cube_size`, edit to `140` — save        |
| 11s  | Browser: cube triples in size                            |
| 13s  | Overlay text (in post): **"No restart. No reconnect. No kicked players."** |
| 15s  | End card: `asobi.dev` / GitHub URL                       |

## Capture tool

- macOS: QuickTime screen recording (Cmd-Shift-5, select the region)
- Linux: OBS Studio or `wf-recorder -g "…"` for a region
- Windows: OBS Studio

Record at **60fps** so the cube-change frame is crisp. Crop to the exact
editor+browser region before exporting.

## Post

- Export as **MP4 (H.264)**, target <5 MB (GitHub embeds MP4 up to 10 MB)
- Also export a **GIF** fallback for non-video contexts (≤5 MB, ~800px wide)
- Overlay captions in post — don't rely on the browser to show them

## Where it goes

- `asobi/README.md` and `asobi_lua/README.md` hero section — drag the MP4
  into any GitHub issue comment, copy the `user-attachments/…` URL,
  paste as `<video src="…" controls></video>` (or `<img>` for the GIF
  fallback).
- `asobi.dev` landing page — upload to the site's CDN / `priv/static/`
- Twitter, Mastodon, Bluesky on launch day — MP4 is widely supported.
- LinkedIn if you're that sort of person.

## Script (if we want a 60-second cut)

Extend the 15-second version:

- 0-5s: same
- 5-15s: show the cube editing (colour, size, bg)
- 15-25s: zoom to the status line "matched — you're in" and call out "no disconnect"
- 25-40s: show `docker compose logs asobi` side panel — point out the "reloading match.lua" log line and that the match PID doesn't change
- 40-55s: quick intercut of the feature bullets from the README ("100K CCU/node", "Apache-2", "self-host")
- 55-60s: end card + URL
