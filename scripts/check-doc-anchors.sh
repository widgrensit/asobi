#!/usr/bin/env bash
# Fails if a guide links to an anchor that ex_doc does not generate.
#
#   scripts/check-doc-anchors.sh
#
# Twenty-three of these accumulated unnoticed. Two ways they get in:
#
#   1. A heading is renamed and inbound links are not swept. `## World capacity`
#      became `## Instance capacity` and four guides kept pointing at the old id.
#   2. The slug is guessed. Wire frames carry a dot, and ex_doc hyphenates it -
#      `world.tick` is `#world-tick`, not `#worldtick`. Six links dropped it.
#
# Neither breaks a build or 404s. The link resolves to the page and silently
# lands the reader at the top of it, which is why these survive for months.
#
# ex_doc only emits ids for h2 and h3 in extras. An h4 heading exists in the
# rendered page but cannot be linked, so a link to one is reported with that
# explanation rather than as a typo - the fix there is to link the parent
# section, not to invent an anchor.
#
# The slugifier below was validated against `rebar3 ex_doc` output: it
# reproduces 703 of the 719 ids in the built HTML, and every one it misses is an
# h4, which has no id to reproduce. Kept in step with ex_doc by that check
# rather than by reading its source.
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import glob
import os
import re
import sys

# Same transformation ex_doc applies to extras headings: strip inline markup,
# lowercase, collapse anything that is not a letter, digit or underscore into a
# single hyphen. Underscores survive (`world.phase_changed` is
# `#world-phase_changed-server-push`).
def slug(text):
    text = re.sub(r'`([^`]*)`', r'\1', text)
    text = re.sub(r'\*\*?([^*]*)\*\*?', r'\1', text)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    return re.sub(r'[^a-z0-9_]+', '-', text.strip().lower()).strip('-')


def page_name(path):
    base = os.path.basename(path)[:-3]
    return 'readme' if base.upper() == 'README' else base


docs = sorted(glob.glob('guides/*.md')) + ['README.md']

# id -> heading level, per page. Level matters: h4 is a real heading with no id.
headings = {}
seen = {}
for path in docs:
    page = page_name(path)
    headings[page] = {}
    seen[page] = {}
    in_fence = False
    for line in open(path, encoding='utf-8'):
        if line.startswith('```'):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r'^(#{2,6})\s+(.*?)\s*$', line)
        if not m:
            continue
        # ex_doc suffixes repeats of a slug, counting the repeats rather than
        # the occurrences: three `### Configuration` on a page give
        # `#configuration`, `#configuration-1`, `#configuration-2`. Dedup is by
        # slug across the whole page, so an h2 and an h3 with the same text
        # collide too. Model it, or every duplicated heading reads as broken.
        base = slug(m.group(2))
        seen[page][base] = seen[page].get(base, 0) + 1
        n = seen[page][base]
        headings[page][base if n == 1 else f"{base}-{n - 1}"] = len(m.group(1))

LINKABLE = (2, 3)
broken = []
checked = 0

for path in docs:
    for m in re.finditer(r'\]\(([^)\s]*\.md)?#([A-Za-z0-9_-]+)\)', open(path, encoding='utf-8').read()):
        target, frag = m.group(1), m.group(2)
        page = page_name(target) if target else page_name(path)
        checked += 1
        if page not in headings:
            broken.append((path, f"{target or ''}#{frag}", f"no guide named {page}.md"))
            continue
        level = headings[page].get(frag)
        if level in LINKABLE:
            continue
        if level is not None:
            broken.append((path, f"{target or ''}#{frag}",
                           f"that heading is h{level}; ex_doc only gives h2/h3 an id - link its parent section"))
            continue
        near = [h for h, lv in headings[page].items()
                if lv in LINKABLE and h.replace('-', '') == frag.replace('-', '')]
        broken.append((path, f"{target or ''}#{frag}",
                       f"did you mean #{near[0]}" if near else "no such heading"))

for path, link, why in broken:
    print(f"  {path}: {link}\n      {why}", file=sys.stderr)

if broken:
    print(f"\n{len(broken)} broken anchor link(s) of {checked} checked.", file=sys.stderr)
    print("A broken anchor does not 404 - it drops the reader at the top of the "
          "page - so nothing else will catch this.", file=sys.stderr)
    sys.exit(1)

print(f"doc anchors: {checked} links checked, all resolve")
PY
