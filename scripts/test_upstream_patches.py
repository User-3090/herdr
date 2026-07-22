from __future__ import annotations

import json
import re
import subprocess
import tempfile
import unittest
from email import policy
from email.parser import BytesParser
from email.utils import parsedate_to_datetime
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import urlsplit


SCHEMA_VERSION = 1
SHA_RE = re.compile(r"[0-9a-f]{40}")
ID_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
MAILBOX_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch")
ENVELOPE_RE = re.compile(r"From ([0-9a-f]{40}) Mon Sep 17 00:00:00 2001")

TOP_LEVEL_KEYS = {"schema_version", "upstream", "active"}
UPSTREAM_KEYS = {"repository", "branch"}
ENTRY_KEYS = {
    "id",
    "title",
    "summary",
    "upstream_base",
    "mailboxes",
    "upstream_refs",
    "reference_notes",
    "touched_paths",
    "verification",
    "remove_when",
}
MAILBOX_KEYS = {"file", "commit"}


class DuplicateKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def validate_keys(
    value: dict[str, Any], expected: set[str], context: str, errors: list[str]
) -> None:
    missing = sorted(expected - value.keys())
    unknown = sorted(value.keys() - expected)
    if missing:
        errors.append(f"{context}: missing fields: {', '.join(missing)}")
    if unknown:
        errors.append(f"{context}: unknown fields: {', '.join(unknown)}")


def read_nonempty_string(value: Any, context: str, errors: list[str]) -> str | None:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{context}: expected a non-empty string")
        return None
    return value


def read_string_list(
    value: Any,
    context: str,
    errors: list[str],
    *,
    allow_empty: bool,
) -> list[str] | None:
    if not isinstance(value, list):
        errors.append(f"{context}: expected an array")
        return None
    if not allow_empty and not value:
        errors.append(f"{context}: expected at least one item")
        return None

    result: list[str] = []
    valid = True
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            errors.append(f"{context}[{index}]: expected a non-empty string")
            valid = False
        else:
            result.append(item)

    if len(result) != len(set(result)):
        errors.append(f"{context}: duplicate values are not allowed")
        valid = False
    return result if valid else None


def is_https_url(value: str) -> bool:
    if any(char.isspace() or ord(char) < 32 for char in value):
        return False
    try:
        parsed = urlsplit(value)
    except ValueError:
        return False
    return (
        parsed.scheme == "https"
        and bool(parsed.netloc)
        and parsed.username is None
        and parsed.password is None
        and not parsed.fragment
    )


def is_safe_repo_path(value: str) -> bool:
    if not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return (
        not path.is_absolute()
        and bool(path.parts)
        and path.as_posix() != "."
        and path.as_posix() == value
        and all(part not in ("", ".", "..") and part.lower() != ".git" for part in path.parts)
    )


def parse_numstat(payload: bytes, context: str, errors: list[str]) -> set[str] | None:
    parts = payload.split(b"\0")
    if parts and parts[-1] == b"":
        parts.pop()

    paths: set[str] = set()
    index = 0
    while index < len(parts):
        fields = parts[index].split(b"\t", 2)
        if len(fields) != 3:
            errors.append(f"{context}: malformed git apply --numstat output")
            return None

        added, deleted, encoded_path = fields
        if not all(count == b"-" or count.isdigit() for count in (added, deleted)):
            errors.append(f"{context}: malformed change counts in git numstat output")
            return None

        encoded_paths: list[bytes]
        if encoded_path:
            encoded_paths = [encoded_path]
            index += 1
        else:
            if index + 2 >= len(parts):
                errors.append(f"{context}: incomplete rename in git numstat output")
                return None
            encoded_paths = [parts[index + 1], parts[index + 2]]
            index += 3

        for encoded in encoded_paths:
            try:
                path = encoded.decode("utf-8")
            except UnicodeDecodeError:
                errors.append(f"{context}: touched path is not valid UTF-8")
                return None
            if not is_safe_repo_path(path):
                errors.append(f"{context}: unsafe or non-canonical touched path {path!r}")
                return None
            paths.add(path)

    if not paths:
        errors.append(f"{context}: mailbox does not contain a non-empty diff")
        return None
    return paths


def validate_mailbox(
    project_root: Path,
    path: Path,
    expected_commit: str,
    context: str,
    errors: list[str],
) -> set[str] | None:
    if not path.is_file():
        errors.append(f"{context}: mailbox file does not exist")
        return None

    try:
        data = path.read_bytes()
        text = data.decode("utf-8")
    except (OSError, UnicodeDecodeError) as error:
        errors.append(f"{context}: cannot read mailbox as UTF-8: {error}")
        return None

    if "\x00" in text:
        errors.append(f"{context}: mailbox contains a NUL byte")
        return None

    normalized = text.replace("\r\n", "\n")
    lines = normalized.splitlines()
    envelope_matches = [
        match for line in lines if (match := ENVELOPE_RE.fullmatch(line)) is not None
    ]
    if not lines or not (first_envelope := ENVELOPE_RE.fullmatch(lines[0])):
        errors.append(f"{context}: first line is not a git format-patch envelope")
    elif first_envelope.group(1) != expected_commit:
        errors.append(
            f"{context}: envelope commit {first_envelope.group(1)} "
            f"does not match index commit {expected_commit}"
        )
    if len(envelope_matches) != 1:
        errors.append(f"{context}: expected exactly one mailbox message")

    first_newline = data.find(b"\n")
    if first_newline < 0:
        errors.append(f"{context}: mailbox has no RFC 2822 headers")
    else:
        message = BytesParser(policy=policy.default).parsebytes(data[first_newline + 1 :])
        for header in ("From", "Date", "Subject"):
            if message.get(header) is None or not str(message[header]).strip():
                errors.append(f"{context}: missing non-empty {header} header")
        if message.defects:
            errors.append(f"{context}: malformed email headers: {message.defects!r}")
        if message.get("Date") is not None:
            try:
                parsedate_to_datetime(str(message["Date"]))
            except (TypeError, ValueError):
                errors.append(f"{context}: Date header is not a valid email date")

    if re.search(r"(?m)^---\s*$", normalized) is None:
        errors.append(f"{context}: missing format-patch message/diff separator")
    if re.search(r"(?m)^diff --git ", normalized) is None:
        errors.append(f"{context}: missing git diff")

    try:
        result = subprocess.run(
            ["git", "apply", "--numstat", "-z", "--no-index", "--", str(path)],
            cwd=project_root,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        errors.append(f"{context}: could not run git apply: {error}")
        return None
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        errors.append(f"{context}: git apply could not parse mailbox: {detail}")
        return None

    return parse_numstat(result.stdout, context, errors)


def parse_series(path: Path, errors: list[str]) -> list[str] | None:
    if not path.is_file():
        errors.append(f"{path}: missing series file")
        return None
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        errors.append(f"{path}: cannot read series as UTF-8: {error}")
        return None

    result: list[str] = []
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if not MAILBOX_RE.fullmatch(line) or PurePosixPath(line).name != line:
            errors.append(f"{path}:{line_number}: invalid mailbox filename {line!r}")
            continue
        result.append(line)

    if len(result) != len(set(result)):
        errors.append(f"{path}: duplicate mailbox filenames are not allowed")
    return result


def validate_archive(project_root: Path) -> list[str]:
    archive_root = project_root / "patches" / "upstream"
    index_path = archive_root / "index.json"
    series_path = archive_root / "series"
    errors: list[str] = []

    try:
        index_data = json.loads(
            index_path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, DuplicateKeyError) as error:
        errors.append(f"{index_path}: cannot load index: {error}")
        return errors

    if not isinstance(index_data, dict):
        return [f"{index_path}: top level must be an object"]
    validate_keys(index_data, TOP_LEVEL_KEYS, str(index_path), errors)

    if type(index_data.get("schema_version")) is not int:
        errors.append(f"{index_path}: schema_version must be an integer")
    elif index_data["schema_version"] != SCHEMA_VERSION:
        errors.append(
            f"{index_path}: unsupported schema_version {index_data['schema_version']!r}; "
            f"expected {SCHEMA_VERSION}"
        )

    upstream = index_data.get("upstream")
    if not isinstance(upstream, dict):
        errors.append(f"{index_path}: upstream must be an object")
    else:
        validate_keys(upstream, UPSTREAM_KEYS, f"{index_path}: upstream", errors)
        repository = read_nonempty_string(
            upstream.get("repository"), f"{index_path}: upstream.repository", errors
        )
        read_nonempty_string(upstream.get("branch"), f"{index_path}: upstream.branch", errors)
        if repository is not None and not is_https_url(repository):
            errors.append(f"{index_path}: upstream.repository must be an HTTPS URL")

    active = index_data.get("active")
    if not isinstance(active, list):
        errors.append(f"{index_path}: active must be an array")
        active = []

    seen_ids: set[str] = set()
    seen_mailboxes: set[str] = set()
    seen_commits: set[str] = set()
    expected_series: list[str] = []
    entry_specs: list[tuple[str, list[tuple[str, str]], list[str] | None]] = []

    for entry_index, entry in enumerate(active):
        context = f"{index_path}: active[{entry_index}]"
        if not isinstance(entry, dict):
            errors.append(f"{context}: expected an object")
            continue
        validate_keys(entry, ENTRY_KEYS, context, errors)

        entry_id = read_nonempty_string(entry.get("id"), f"{context}.id", errors)
        if entry_id is not None:
            if not ID_RE.fullmatch(entry_id):
                errors.append(f"{context}.id: expected a lowercase dash-separated identifier")
            if entry_id in seen_ids:
                errors.append(f"{context}.id: duplicate identifier {entry_id!r}")
            seen_ids.add(entry_id)

        for field in ("title", "summary", "remove_when"):
            read_nonempty_string(entry.get(field), f"{context}.{field}", errors)

        upstream_base = read_nonempty_string(
            entry.get("upstream_base"), f"{context}.upstream_base", errors
        )
        if upstream_base is not None and not SHA_RE.fullmatch(upstream_base):
            errors.append(f"{context}.upstream_base: expected a full lowercase commit ID")

        refs = read_string_list(
            entry.get("upstream_refs"),
            f"{context}.upstream_refs",
            errors,
            allow_empty=True,
        )
        if refs is not None:
            for ref_index, ref in enumerate(refs):
                if not is_https_url(ref):
                    errors.append(f"{context}.upstream_refs[{ref_index}]: expected an HTTPS URL")

        read_string_list(
            entry.get("reference_notes"),
            f"{context}.reference_notes",
            errors,
            allow_empty=True,
        )

        touched_paths = read_string_list(
            entry.get("touched_paths"),
            f"{context}.touched_paths",
            errors,
            allow_empty=False,
        )
        if touched_paths is not None:
            for path_index, touched_path in enumerate(touched_paths):
                if not is_safe_repo_path(touched_path):
                    errors.append(
                        f"{context}.touched_paths[{path_index}]: "
                        "expected a canonical repository-relative POSIX path"
                    )
            if touched_paths != sorted(touched_paths):
                errors.append(f"{context}.touched_paths: paths must be sorted")

        read_string_list(
            entry.get("verification"),
            f"{context}.verification",
            errors,
            allow_empty=False,
        )

        mailbox_specs: list[tuple[str, str]] = []
        mailboxes = entry.get("mailboxes")
        if not isinstance(mailboxes, list) or not mailboxes:
            errors.append(f"{context}.mailboxes: expected a non-empty array")
        else:
            for mailbox_index, mailbox in enumerate(mailboxes):
                mailbox_context = f"{context}.mailboxes[{mailbox_index}]"
                if not isinstance(mailbox, dict):
                    errors.append(f"{mailbox_context}: expected an object")
                    continue
                validate_keys(mailbox, MAILBOX_KEYS, mailbox_context, errors)
                filename = read_nonempty_string(
                    mailbox.get("file"), f"{mailbox_context}.file", errors
                )
                commit = read_nonempty_string(
                    mailbox.get("commit"), f"{mailbox_context}.commit", errors
                )
                filename_is_valid = False
                if filename is not None:
                    if not MAILBOX_RE.fullmatch(filename) or PurePosixPath(filename).name != filename:
                        errors.append(
                            f"{mailbox_context}.file: expected a local .patch filename"
                        )
                    else:
                        filename_is_valid = True
                        if filename in seen_mailboxes:
                            errors.append(f"{mailbox_context}.file: duplicate mailbox {filename!r}")
                        seen_mailboxes.add(filename)
                        expected_series.append(filename)
                commit_is_valid = False
                if commit is not None:
                    if not SHA_RE.fullmatch(commit):
                        errors.append(
                            f"{mailbox_context}.commit: expected a full lowercase commit ID"
                        )
                    else:
                        commit_is_valid = True
                        if commit in seen_commits:
                            errors.append(f"{mailbox_context}.commit: duplicate commit {commit!r}")
                        seen_commits.add(commit)
                if filename_is_valid and commit_is_valid:
                    assert filename is not None and commit is not None
                    mailbox_specs.append((filename, commit))

        entry_specs.append((context, mailbox_specs, touched_paths))

    listed_series = parse_series(series_path, errors)
    if listed_series is not None and listed_series != expected_series:
        errors.append(
            f"{series_path}: entries must exactly match active mailbox order "
            f"(expected {expected_series!r}, found {listed_series!r})"
        )

    actual_mailboxes = sorted(
        path.relative_to(archive_root).as_posix()
        for path in archive_root.rglob("*.patch")
        if path.is_file()
    )
    indexed_mailboxes = sorted(seen_mailboxes)
    if actual_mailboxes != indexed_mailboxes:
        missing = sorted(set(indexed_mailboxes) - set(actual_mailboxes))
        unindexed = sorted(set(actual_mailboxes) - set(indexed_mailboxes))
        if missing:
            errors.append(f"{archive_root}: indexed mailbox files are missing: {missing!r}")
        if unindexed:
            errors.append(f"{archive_root}: unindexed mailbox files exist: {unindexed!r}")

    for context, mailbox_specs, touched_paths in entry_specs:
        actual_paths: set[str] = set()
        complete = True
        for filename, commit in mailbox_specs:
            mailbox_paths = validate_mailbox(
                project_root,
                archive_root / filename,
                commit,
                f"{archive_root / filename}",
                errors,
            )
            if mailbox_paths is None:
                complete = False
            else:
                actual_paths.update(mailbox_paths)
        if complete and touched_paths is not None and sorted(actual_paths) != touched_paths:
            errors.append(
                f"{context}.touched_paths: metadata does not match mailbox diffs "
                f"(expected {sorted(actual_paths)!r}, found {touched_paths!r})"
            )

    return errors


SAMPLE_COMMIT = "1" * 40
SAMPLE_MAILBOX = f"""From {SAMPLE_COMMIT} Mon Sep 17 00:00:00 2001
From: Archive Test <archive@example.com>
Date: Tue, 21 Jul 2026 12:00:00 +0000
Subject: [PATCH] test archive fixture

Fixture mailbox.
---
 example.txt | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

diff --git a/example.txt b/example.txt
index 1111111..2222222 100644
--- a/example.txt
+++ b/example.txt
@@ -1 +1 @@
-before
+after
--
2.50.0
"""


def write_fixture(project_root: Path, *, populated: bool) -> None:
    archive_root = project_root / "patches" / "upstream"
    archive_root.mkdir(parents=True)
    active: list[dict[str, Any]] = []
    series = ""
    if populated:
        mailbox = "0001-test-archive-fixture.patch"
        active.append(
            {
                "id": "test-archive-fixture",
                "title": "Test archive fixture",
                "summary": "Exercises populated archive validation.",
                "upstream_base": "0" * 40,
                "mailboxes": [{"file": mailbox, "commit": SAMPLE_COMMIT}],
                "upstream_refs": [],
                "reference_notes": [],
                "touched_paths": ["example.txt"],
                "verification": ["python -m unittest scripts.test_upstream_patches"],
                "remove_when": "The fixture test no longer needs a populated archive.",
            }
        )
        (archive_root / mailbox).write_text(SAMPLE_MAILBOX, encoding="utf-8")
        series = f"{mailbox}\n"

    index = {
        "schema_version": SCHEMA_VERSION,
        "upstream": {
            "repository": "https://github.com/ogulcancelik/herdr",
            "branch": "master",
        },
        "active": active,
    }
    (archive_root / "index.json").write_text(
        json.dumps(index, indent=2) + "\n", encoding="utf-8"
    )
    (archive_root / "series").write_text(series, encoding="utf-8")


class UpstreamPatchArchiveTests(unittest.TestCase):
    def test_repository_archive_is_valid(self) -> None:
        project_root = Path(__file__).resolve().parent.parent
        errors = validate_archive(project_root)
        self.assertEqual(errors, [], "\n" + "\n".join(errors))

    def test_validator_accepts_empty_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            write_fixture(project_root, populated=False)
            self.assertEqual(validate_archive(project_root), [])

    def test_validator_accepts_populated_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            write_fixture(project_root, populated=True)
            self.assertEqual(validate_archive(project_root), [])

    def test_numstat_parser_includes_both_rename_paths(self) -> None:
        errors: list[str] = []
        paths = parse_numstat(b"0\t0\t\0old.txt\0new.txt\0", "fixture", errors)
        self.assertEqual(errors, [])
        self.assertEqual(paths, {"old.txt", "new.txt"})

    def test_validator_rejects_series_and_touched_path_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            write_fixture(project_root, populated=True)
            archive_root = project_root / "patches" / "upstream"
            index = json.loads((archive_root / "index.json").read_text(encoding="utf-8"))
            index["active"][0]["touched_paths"] = ["wrong.txt"]
            (archive_root / "index.json").write_text(
                json.dumps(index, indent=2) + "\n", encoding="utf-8"
            )
            (archive_root / "series").write_text("", encoding="utf-8")

            errors = "\n".join(validate_archive(project_root))
            self.assertIn("entries must exactly match active mailbox order", errors)
            self.assertIn("metadata does not match mailbox diffs", errors)


if __name__ == "__main__":
    unittest.main()
