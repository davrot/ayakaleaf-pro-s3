# Overleaf — filesystem → S3 (SeaweedFS) filestore migration

Tools to move a legacy Overleaf **local filestore** (`/var/lib/overleaf/data`)
into the **S3 filestore** on SeaweedFS used by the current Overleaf stack
(6.3.4). The legacy backup is treated as strictly **read-only**; the import is
an idempotent, byte-level copy to S3 with MD5 verification.

## What moves

| Legacy dir (under `/var/lib/overleaf/data`) | S3 bucket | Key rule |
|---|---|---|
| `user_files/…` | `overleaf-user-files` | first `_` of top-level element → `/` |
| `template_files/…` | `overleaf-template-files` | same |
| `history/overleaf-chunks/…` | `overleaf-chunks` | verbatim |
| `history/overleaf-project-blobs/…` | `overleaf-project-blobs` | verbatim |
| `output/…` *(opt-in)* | `overleaf-user-files` | verbatim |
| `*.zip` exports *(opt-in)* | `overleaf-user-files` | `exports/<name>` |

`cache/`, `compiles/`, `tmp/` are transient and **not** migrated.

> Per the official guide, Overleaf ≥ 6.0.0 no longer uses the legacy
> `user_files` store — in practice only `template_files` + the two history
> dirs carry data. The tools still copy `user_files` if present (harmless; it
> is usually empty), so this toolset is safe on both old and new backups.

**Key rule** (user_files / template_files only): the local layout is
`<project-id>_<file-id>`, the S3 layout is `<project-id>/<file-id>` — the first
top-level underscore becomes a slash. History directories already match the
S3 layout and upload verbatim.

## Prerequisites

* `python3` + `boto3` (`pip install boto3`)
* The target S3 (SeaweedFS) reachable from the host at `S3_ENDPOINT`
  (default `http://127.0.0.1:8333`) with the four buckets present
* The legacy backup under `LEGACY_ROOT` (default `/root/other_server/compose_cep`)
* The target stack's `.env` (AWS keys + bucket names) — loaded automatically

All settings live in `common.conf` and can be overridden by exporting the same
variable name before calling a tool (env wins over the file).

## Run

```text
 1  preflight.sh                              readonly sanity of legacy + target
 2  wipe-targets.sh --yes                      (optional) blank-slate the S3 buckets
 3  import-s3.sh --reimport [--with-exports]  import filestore/history → S3
 4  verify.sh                                  automated checks + manual UI checklist
```

Or `./run-all.sh` (add `--yes-all --wipe` for a hands-off run; `STEP=n`
resumes at step n). All destructive tools require `--yes`; all support
`--dry-run`.

## Per-server notes

* **Keep the legacy `/var/lib/overleaf` bind-mount.** It may hold Zotero /
  Mendeley encryption keys that are not stored in S3 (official guide).
* Config (invite token, OIDC/Zotero/GitHub client creds, site identity) is
  **not** part of the filestore — copy it from the legacy `.env` to the target
  and confirm it with `preflight.sh`.
* Legacy export zips (`overleafserver/*.zip`) are imported only with
  `--with-exports` (as `exports/<name>`).

## Rollback

The legacy backup is never modified. To roll back, point the stack back to the
local filestore (or `aws s3 sync` the buckets to a scratch dir) and start the
legacy server, which is frozen and unchanged until cutover.

## Files

| file | purpose |
|---|---|
| `common.conf` | all paths / containers / buckets — override via env |
| `preflight.sh` | readonly readiness check (incl. config diff) |
| `import-s3.sh` / `s3-import.py` | filestore → S3 (parallel, resumable, MD5-verified) |
| `wipe-targets.sh` | optional blank-slate of the target S3 buckets |
| `verify.sh` | automated post-import checks + manual UI checklist |
| `run-all.sh` | orchestrator with human gates |
