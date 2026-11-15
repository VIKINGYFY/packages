#!/usr/bin/env python3

"""Rebase generated pagination index hunks while preserving upstream schema changes."""

import copy
import difflib
import json
from pathlib import Path
import re
import sys


ANCHOR = {
    "fields": ["project_id", "created_at"],
    "storage_key": "requests_by_project_id_created_at",
}
INDEX = {
    "fields": ["project_id", "id"],
    "storage_key": "requests_by_project_id_id",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def snapshot_line(text, prefix):
    matches = list(re.finditer(r"^" + re.escape(prefix) + r"const Schema = (.+)$", text, re.M))
    require(len(matches) == 1, "expected exactly one " + prefix + "const Schema line")
    return matches[0]


def decode(literal):
    # Ent emits a quoted Go string containing compact JSON. JSON decoding also
    # rejects any unexpected Go literal format instead of guessing at escapes.
    return json.loads(json.loads(literal))


def request_indexes(snapshot):
    requests = [schema for schema in snapshot["Schemas"] if schema["name"] == "Request"]
    require(len(requests) == 1, "expected exactly one Request schema")
    return requests[0]["indexes"]


def migration_index(index, columns):
    references = ", ".join(f"RequestsColumns[{columns[field]}]" for field in index["fields"])
    return ("\t\t\t{\n"
            f'\t\t\t\tName:    "{index["storage_key"]}",\n'
            "\t\t\t\tUnique:  false,\n"
            f"\t\t\t\tColumns: []*schema.Column{{{references}}},\n"
            "\t\t\t},\n")


def rebase_migration(source, text):
    path = "internal/ent/migrate/schema.go"
    header = f"--- a/{path}\n+++ b/{path}\n"
    sections = list(re.finditer(re.escape(header) + r"(.*?)(?=^--- |\Z)", text, re.M | re.S))
    require(len(sections) == 1, "expected exactly one migration patch section")
    section = sections[0]
    lines = section[1].splitlines(keepends=True)
    require(sum(line.startswith("@@ ") for line in lines) == 1,
            "expected exactly one migration hunk")
    require(not any(line.startswith("-") for line in lines),
            "migration patch must not remove upstream code")
    added = "".join(line[1:] for line in lines if line.startswith("+"))
    project = re.search(r"RequestsColumns\[(\d+)\], RequestsColumns\[0\]", added)
    require(project is not None, "unexpected migration index columns")
    expected = migration_index(INDEX, {"project_id": int(project[1]), "id": 0}).splitlines(keepends=True)
    # Diff tools can align shared braces with either neighboring index. Accept
    # those rotations while requiring exactly the same five inserted lines.
    require(any(added == "".join(expected[i:] + expected[:i]) for i in range(len(expected))),
            "migration patch contains changes beyond the pagination index")

    current = (source / path).read_text()
    blocks = list(re.finditer(r"^\tRequestsColumns = \[\]\*schema.Column\{\n(.*?)^\t\}",
                              current, re.M | re.S))
    require(len(blocks) == 1, "expected exactly one RequestsColumns declaration")
    names = re.findall(r'^\t\t\{Name: "([^"\n]+)",', blocks[0][1], re.M)
    require(len(names) == len(blocks[0][1].splitlines()) and len(set(names)) == len(names),
            "unexpected migration column encoding")
    columns = {name: position for position, name in enumerate(names)}
    anchor = migration_index(ANCHOR, columns)
    require(current.count(anchor) == 1, "upstream migration pagination anchor changed")
    require(f'Name:    "{INDEX["storage_key"]}"' not in current,
            "upstream migration already defines the pagination index; review the patch")
    desired = current.replace(anchor, anchor + migration_index(INDEX, columns))
    refreshed = "".join(difflib.unified_diff(current.splitlines(keepends=True),
                                             desired.splitlines(keepends=True),
                                             fromfile="a/" + path, tofile="b/" + path))
    return text[:section.start()] + refreshed + text[section.end():]


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: rebase-axonhub-schema.py <upstream-source-dir> <patch-file>")

    source = Path(sys.argv[1])
    patch = Path(sys.argv[2])
    text = patch.read_bytes().decode()
    before = snapshot_line(text, "-")
    after = snapshot_line(text, "+")
    old_snapshot = decode(before[1])
    patched_snapshot = decode(after[1])
    indexes = request_indexes(patched_snapshot)
    require(indexes.count(INDEX) == 1, "patch must add exactly the pagination index")
    position = indexes.index(INDEX)
    require(position > 0 and indexes[position - 1] == ANCHOR, "unexpected index placement")
    indexes.pop(position)
    require(patched_snapshot == old_snapshot, "snapshot patch contains other schema changes")
    require(all(index.get("storage_key") != INDEX["storage_key"]
                for index in request_indexes(old_snapshot)), "base already has the pagination index")

    current = snapshot_line((source / "internal/ent/internal/schema.go").read_text(), "")
    upstream = decode(current[1])
    desired = copy.deepcopy(upstream)
    indexes = request_indexes(desired)
    require(indexes.count(ANCHOR) == 1, "upstream pagination anchor changed")
    require(all(index.get("storage_key") != INDEX["storage_key"] for index in indexes),
            "upstream already defines the pagination index; review the patch")
    indexes.insert(indexes.index(ANCHOR) + 1, INDEX)

    # Splice only the added index into the original Go literal. Preserve every
    # unrelated byte, including Ent's JSON and Go string escaping.
    anchor_json = json.dumps(ANCHOR, separators=(",", ":"))
    index_json = json.dumps(INDEX, separators=(",", ":"))
    anchor_literal = json.dumps(anchor_json)[1:-1]
    replacement = json.dumps(anchor_json + "," + index_json)[1:-1]
    require(current[1].count(anchor_literal) == 1, "unexpected snapshot encoding")
    new_literal = current[1].replace(anchor_literal, replacement)
    require(decode(new_literal) == desired, "rebased snapshot differs from the expected index addition")

    # All checks finish before touching the temporary input patch. Quilt still
    # applies and verifies the authored schema hunk normally.
    for match, literal in sorted([(before, current[1]), (after, new_literal)],
                                 key=lambda item: item[0].start(), reverse=True):
        text = text[:match.start(1)] + literal + text[match.end(1):]
    text = rebase_migration(source, text)
    patch.write_bytes(text.encode())
    print("已按上游 Ent 快照和迁移列定义重定位请求分页索引补丁。")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError) as error:
        sys.exit("AxonHub schema snapshot conflict: " + str(error))
