#!/usr/bin/env bash
# USER-overlay engine.
#
# Preserve keyed user regions across regeneration:
#   <!-- BEGIN USER: <key> -->
#   ... user content (verbatim) ...
#   <!-- END USER: <key> -->
#
# overlay_merge OLD NEW prints NEW to stdout with every USER region re-injected
# from OLD by matching key. A key present in OLD but absent from NEW is never
# dropped: it is parked under a clearly-marked orphan trailer so the user can
# re-home or delete it. python3 is used for robust extraction; without it the
# merge degrades to "emit NEW as-is" with a warning (no preservation).

overlay_merge() {
  local old="$1" new="$2"
  if command -v python3 >/dev/null 2>&1; then
    OVERLAY_OLD="$old" OVERLAY_NEW="$new" python3 - <<'PY'
import os
import re
import sys

old_path = os.environ.get("OVERLAY_OLD", "")
new_path = os.environ["OVERLAY_NEW"]

old = ""
if old_path and os.path.exists(old_path):
    with open(old_path, encoding="utf-8") as handle:
        old = handle.read()
with open(new_path, encoding="utf-8") as handle:
    new = handle.read()

marker_pattern = re.compile(r"^<!-- (BEGIN|END) USER: ([^>]+?) -->$")


def marker_for(line):
    match = marker_pattern.match(line.rstrip("\r\n"))
    if not match:
        return None
    return match.group(1), match.group(2)


def trim_separator_newline(body):
    if body.endswith("\r\n"):
        return body[:-2]
    if body.endswith("\n") or body.endswith("\r"):
        return body[:-1]
    return body


def line_ending(line):
    if line.endswith("\r\n"):
        return "\r\n"
    if line.endswith("\n"):
        return "\n"
    if line.endswith("\r"):
        return "\r"
    return ""


def user_regions(text):
    lines = []
    offset = 0
    for line in text.splitlines(True):
        start = offset
        offset += len(line)
        lines.append((start, offset, line))

    begin_lines = []
    for index, (_, _, line) in enumerate(lines):
        marker = marker_for(line)
        if marker and marker[0] == "BEGIN":
            begin_lines.append((index, marker[1]))

    for begin_pos, (begin_index, key) in enumerate(begin_lines):
        next_begin = (
            begin_lines[begin_pos + 1][0]
            if begin_pos + 1 < len(begin_lines)
            else len(lines)
        )
        close_index = None
        for index in range(begin_index + 1, next_begin):
            marker = marker_for(lines[index][2])
            if marker == ("END", key):
                close_index = index
        if close_index is None:
            continue
        body_start = lines[begin_index][1]
        body_end = lines[close_index][0]
        yield {
            "start": lines[begin_index][0],
            "end": lines[close_index][1],
            "key": key,
            "body": trim_separator_newline(text[body_start:body_end]),
            "suffix": line_ending(lines[close_index][2]),
        }


def render_region(key, body):
    return "<!-- BEGIN USER: %s -->\n%s\n<!-- END USER: %s -->" % (
        key,
        body,
        key,
    )


old_regions = {}
for region in user_regions(old):
    old_regions[region["key"]] = region["body"]

used = set()


merged_parts = []
position = 0
for region in user_regions(new):
    if region["start"] < position:
        continue
    key = region["key"]
    merged_parts.append(new[position:region["start"]])
    if key in old_regions:
        used.add(key)
        merged_parts.append(render_region(key, old_regions[key]))
        merged_parts.append(region["suffix"])
    else:
        merged_parts.append(new[region["start"]:region["end"]])
    position = region["end"]
merged_parts.append(new[position:])
merged = "".join(merged_parts)

orphans = [key for key in old_regions if key not in used]
if orphans:
    merged = merged.rstrip("\n") + (
        "\n\n<!-- USER (orphaned): re-home into a current USER block or delete -->\n"
    )
    for key in orphans:
        merged += render_region(key, old_regions[key]) + "\n"

sys.stdout.write(merged)
PY
  else
    printf 'agent-bootstrap: warn: python3 missing; USER overlays not preserved (no merge)\n' >&2
    cat "$new"
  fi
}
