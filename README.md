# Overleaf 6.2.0 → 6.3.1: filesystem → SeaweedFS(S3) migration — plan & tools

Reproducible migration of the legacy Overleaf **filestore** (e.g.
`overleaf.pip.uni-bremen.de`, `sharelatex/sharelatex:6.2.0`) into the new
stack at `/data_1/docker/compose` (`sharelatex/sharelatex:ext-ce-v6.3.1`,
S3 filestore on SeaweedFS), developed on the **test server** so nothing
meaningful can be destroyed.

All tools live in this directory and are parameterized via `common.conf`
(env vars override), so the SAME toolset migrates every other server — you
only change the source backup location.

## 1. What actually has to move (verified against the real backup)

The legacy 6.2.0 filestore data plane (from `/root/other_server/compose_cep`,
host dir `overleafserver/data` ≙ `/var/lib/overleaf/data`):

| Data | Location (legacy) | Migration target (new stack) |
|---|---|---|
| **History chunk content** (Go history-v1, 6.2): **12 557 files, 3.7 GB** under `data/history/overleaf-chunks/<revproj3>/<revproj3>/<revproj18>/<chunkid>` | `overleafserver/data/data/history/overleaf-chunks` | **S3 bucket `overleaf-chunks`** — layout already 1:1 (see §5) |
| Uploaded binary files | `data/user_files` — **0 files** on this server | S3 bucket `overleaf-user-files` (generic tooling supports it) |
| Template files | `data/template_files` — **0 files** | S3 bucket `overleaf-template-files` (generic tooling) |
| History project-blobs (S3 style) | `data/history/overleaf-project-blobs` — **absent** here (blobs live in mongo `projectHistoryBlobs`, 0.5 MB) | S3 bucket `overleaf-project-blobs` (generic tooling) |
| Legacy export zips | `overleafserver/*.zip` (1 here) | S3 bucket `overleaf-user-files` as `exports/<name>` (opt-in `--with-exports`) |
| Ephemeral (`cache/`, `compiles/`, `tmp/`) — NOT migrated | — | regenerated on first compile/upload |

## 2. Config continuity (what was verified)

* **No filesystem path or docker hostname is embedded in the filestore
  data** — the import is a pure byte-level copy to S3.
* `OVERLEAF_FILESTORAGE_LOCATION` / S3 bucket config are **config only** —
  the new compose already points at `s3:8333` with the bucket names above.
* Invite tokens: `OVERLEAF_INVITE_TOKEN_SECRET` is **already the same
  value** in both `.env` files (verified) — legacy invite links keep working.
* Third-party clients: legacy vs target `.env` differ on
  `OVERLEAF_OIDC_CLIENT_ID` (`overleaf_pip` vs `overleaf_test`),
  `ZOTERO_CLIENT_KEY/SECRET`, `GITHUB_SYNC_CLIENT_ID/SECRET` — decide per
  server (a fresh Keycloak app registration may be needed for a brand-new
  site).

## 3. Execution order (one server)

```text
 1  preflight.sh                              readonly sanity of legacy+target
 2  wipe-targets.sh --yes                      (optional) blank-slate S3 buckets
 3  import-s3.sh --reimport [--with-exports]  legacy filestore/history → S3
 4  verify.sh                                  automated + manual UI checklist
```

`run-all.sh` drives the steps with pauses (`STEP=n` resumes at step n).
All destructive tools require `--yes`; all support `--dry-run`; the legacy
backup is strictly READ-ONLY.

## 4. S3 key layout (official rules, confirmed in 6.3.1 source)

Official migration guide
(docs.overleaf.com/on-premises/maintenance/s3-migration): local filestore
layout is `<project-id>_<file-id>`, S3 layout is `<project-id>/<file-id>`
(first top-level underscore → slash); **history directories already have the
correct layout** and upload verbatim. Cross-checked against the
`ext-ce-v6.3.1` source: `sharelatex` ProjectKey (`naiveReverse(projectId)`
split 3/3/18) — the legacy disk layout
`overleaf-chunks/920/9ac/238ed6e0acf76502a6/6a205af8…` is exactly
`<reversed-pid 3/3/18>/<chunkObjectId>`, i.e. verbatim upload is correct.

| legacy dir (under `/var/lib/overleaf/data`) | bucket | key rule |
|---|---|---|
| `user_files/…` | `overleaf-user-files` | first `_` of top element → `/` |
| `template_files/…` | `overleaf-template-files` | same |
| `history/overleaf-chunks/…` | `overleaf-chunks` | verbatim |
| `history/overleaf-project-blobs/…` | `overleaf-project-blobs` | verbatim |
| `output/…` (opt-in `--with-ephemeral`) | `overleaf-user-files` | verbatim |
| `*.zip` exports (opt-in `--with-exports`) | `overleaf-user-files` | `exports/<name>` |

## 5. Per-server checklist (the repeatable workflow)

1. On the LEGACY server (maintenance window), stop writers and take a
   consistent snapshot:
   * `docker stop <app> git-bridge` (writers off)
   * copy/rsync `overleafserver/data` (the filestore) plus `.env` and
     per-service `compose.yaml` to the new host under a fresh `LEGACY_ROOT`
2. On the NEW host: `export LEGACY_ROOT=/path/to/this-server-backup`
   (or edit the default in `common.conf`), then
   `./run-all.sh --yes-all --wipe` (or step by step with `STEP=`).
3. `./verify.sh`, walk the UI checklist.
4. Point DNS/proxy at the new stack only after the checklist is green;
   keep the legacy server (frozen) until rollback window ends.

## 6. Rollback

* S3: `aws s3 sync s3://overleaf-chunks <scratch>` (and the other buckets),
  then restore the legacy data dir into the legacy stack (the legacy
  server is frozen/unchanged until cutover).
* The legacy backup stays READ-ONLY the whole time — the original is
  always restorable.

## 7. Open decisions (per server)

1. **Third-party clients**: legacy vs target `.env` differ on
   `OVERLEAF_OIDC_CLIENT_ID`, `ZOTERO_CLIENT_KEY/SECRET`,
   `GITHUB_SYNC_CLIENT_ID/SECRET` — decide per server whether the migrated
   instance should use the old or new client.
2. **Site identity**: `OVERLEAF_SITE_URL` / app name / footers come from
   the TARGET `.env` (the new identity) — expected.
3. **Legacy export zips** (`overleafserver/*.zip`, 1 here): import as
   `exports/<name>` with `--with-exports`, or leave behind.

## 8. Files

| file | purpose |
|---|---|
| `common.conf` | all paths/containers/buckets — override via env |
| `preflight.sh` | readonly readiness check (incl. config diff) |
| `import-s3.sh` / `s3-import.py` | legacy filestore → S3 (parallel, resumable, MD5-verified) |
| `wipe-targets.sh` | optional blank-slate of the target S3 buckets |
| `verify.sh` | automated post-import checks + manual UI checklist |
| `run-all.sh` | orchestrator with human gates |
