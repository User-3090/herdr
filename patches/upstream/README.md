# Maintained upstream patch archive

This directory is the source of truth for fork-only product fixes that are
intended to remain reviewable and replayable on top of
[`ogulcancelik/herdr`](https://github.com/ogulcancelik/herdr). It does not track
fork-only CI, packaging, or release automation.

Everything here is validated offline. The validator reads local files and uses
`git apply --numstat`; it never fetches upstream state.

## Files

- `index.json` contains schema-versioned metadata for active logical fixes.
- `series` lists active mailbox files in application order, one filename per
  line. Blank lines and full-line `#` comments are ignored.
- `*.patch` files are single-commit mailboxes produced by `git format-patch`.
- `scripts/test_upstream_patches.py` validates the index, mailbox inventory,
  series order, mailbox structure, and touched-path metadata.

An empty `active` array and an empty `series` are valid.

## `index.json` schema version 1

The top-level object has exactly these fields:

| Field | Meaning |
| --- | --- |
| `schema_version` | Integer `1`. Any incompatible schema change must increment it. |
| `upstream` | Object with the canonical HTTPS `repository` URL and default `branch`. |
| `active` | Ordered array of active logical-fix entries. |

Each active entry has exactly these fields:

| Field | Meaning |
| --- | --- |
| `id` | Stable lowercase dash-separated identifier. |
| `title` | Short human-readable fix name. |
| `summary` | Why the fork carries the fix. |
| `upstream_base` | Full lowercase commit ID the mailbox set is based on. |
| `mailboxes` | Non-empty ordered array of `{ "file", "commit" }` objects. Each file is local to this directory and each full commit ID must match its mailbox envelope. |
| `upstream_refs` | HTTPS issue, discussion, or pull-request URLs; use an empty array until one exists. |
| `reference_notes` | Notes that distinguish exact issue coverage from contextual references or record why no dedicated upstream issue exists. |
| `touched_paths` | Sorted, unique, repository-relative POSIX paths touched by all entry mailboxes. Include both old and new names for renames. |
| `verification` | Non-empty array of commands or concrete manual checks for the logical fix. |
| `remove_when` | Exact condition under which the fix can leave the active archive. |

Unknown fields are rejected so metadata additions remain deliberate and
schema-versioned. Mailbox filenames, mailbox commit IDs, entry IDs, and touched
paths must be unique where applicable. The flattened mailbox order from
`active` must exactly match `series`, and every `*.patch` file must be indexed.

## Add or refresh a logical fix

1. Start from the recorded upstream base and make the logical fix a clean
   commit (or a small ordered commit set).
2. Export each commit as a full-index binary-safe mailbox, for example:

   ```bash
   git format-patch --full-index --binary -1 <commit> --output-directory patches/upstream
   ```

3. Add one active entry to `index.json`. Record mailboxes in application order
   and set `touched_paths` to the exact sorted union of paths in those files.
4. Add the mailbox filenames to `series` in the same flattened order.
5. Update the fork status/fixes block at the top of the root `README.md` if the
   set of active logical fixes changed.
6. Run the offline validator:

   ```bash
   python -m unittest scripts.test_upstream_patches
   ```

When rebasing a mailbox, update its envelope commit, `upstream_base`, touched
paths, and verification evidence together. Do not hand-edit a diff merely to
make validation pass; regenerate it from the reviewed commit.

## Retire a fix

Confirm the removal condition against an upstream revision, then remove the
active entry and its mailbox files, remove their lines from `series`, update the
root fork status/fixes block, and rerun the validator. Git history retains the
retired archive record.
