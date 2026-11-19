#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# import-s3.sh — import the legacy 6.2.0 filestore into the new S3 plane
# (SeaweedFS buckets), per the official Overleaf fs→S3 migration rules.
#
# Stores (legacy /var/lib/overleaf/data relative) → bucket:
#   user_files                 → overleaf-user-files        (key: <pj>_<file> → <pj>/<file>)
#   template_files             → overleaf-template-files    (same transform)
#   history/overleaf-chunks    → overleaf-chunks            (verbatim)
#   history/overleaf-project-blobs → overleaf-project-blobs (verbatim)
#   output (opt-in)            → overleaf-user-files        (opt-in, verbatim)
#   legacy export *.zip (opt-in) → exports/<name>
#
# Transient leftovers (cache/, compiles/, tmp/) are NOT imported.
#
# Flags:
#   --reimport        wipe the target buckets before importing (fresh import)
#   --skip-existing   skip objects already present with identical size+MD5
#   --with-ephemeral  also import output/ (build artifacts)
#   --with-exports    also import legacy export zips as exports/<name>
#   --dry-run         show the plan, change nothing
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=./common.conf
. ./common.conf

REIMPORT=0; SKIP_EXISTING=0; WITH_EPHEMERAL=0; WITH_EXPORTS=0; DRY_RUN=0
for a in "$@"; do case "$a" in
  --reimport) REIMPORT=1 ;;
  --skip-existing) SKIP_EXISTING=1 ;;
  --with-ephemeral) WITH_EPHEMERAL=1 ;;
  --with-exports) WITH_EXPORTS=1 ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown flag: $a (try --help)" ;;
esac; done

require_cmd python3
python3 -c 'import boto3' 2>/dev/null || die "python3 + boto3 required (pip install boto3)"
require_container "${TARGET_SEAWEEDFS_S3_CONTAINER}"
require_cmd aws || true   # aws CLI optional (boto3 does the work)

LEGACY_DATA="${LEGACY_SERVER_DATA}/data"
[ -d "${LEGACY_DATA}" ] || die "legacy filestore data root not found: ${LEGACY_DATA} (LEGACY_SERVER_DATA=${LEGACY_SERVER_DATA})"

load_target_env   # AWS credentials + bucket names from the target .env
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
S3_ID="${AWS_ACCESS_KEY_ID:-}"; S3_KEY="${AWS_SECRET_ACCESS_KEY:-}"

STORES="user_files,template_files"
[ -d "${LEGACY_DATA}/history/overleaf-chunks" ]        && STORES="${STORES},history/overleaf-chunks"
[ -d "${LEGACY_DATA}/history/overleaf-project-blobs" ] && STORES="${STORES},history/overleaf-project-blobs"
[ "${WITH_EPHEMERAL}" -eq 1 ] && [ -d "${LEGACY_DATA}/output" ] && STORES="${STORES},output"
export OUTPUT_BUCKET="${OUTPUT_BUCKET:-overleaf-user-files}"

log "target S3     : ${S3_ENDPOINT}"
log "legacy data   : ${LEGACY_DATA}"
for s in $(echo "${STORES}" | tr ',' ' '); do
  if [ -d "${LEGACY_DATA}/${s}" ]; then
    NF=$(find "${LEGACY_DATA}/${s}" -type f 2>/dev/null | wc -l | tr -d ' ')
    SZ=$(du -sh "${LEGACY_DATA}/${s}" 2>/dev/null | cut -f1)
    if [ "${NF}" -eq 0 ]; then
      log "  ${s}: (0 files — will be skipped)"
    else
      log "  ${s}: ${NF} files (${SZ})"
    fi
  else
    log "  ${s}: (absent from legacy data — skipped)"
  fi
done

# Legacy export zips sitting at the old /var/lib/overleaf level.
EXTRA=""
if [ "${WITH_EXPORTS}" -eq 1 ]; then
  shopt -s nullglob
  for z in "${LEGACY_SERVER_DATA}"/*.zip; do
    EXTRA="${EXTRA:+${EXTRA};}${z}=exports/$(basename "${z}")"
  done
fi
[ -n "${EXTRA}" ] && log "extra objects : $(echo "${EXTRA}" | tr ';' '\n' | wc -l) legacy export zip(s)"
log "reimport? ${REIMPORT}   skip-existing? ${SKIP_EXISTING}"

if [ "${DRY_RUN}" -eq 1 ]; then log "dry-run: nothing was changed."; exit 0; fi

S3_ENDPOINT="${S3_ENDPOINT}" LEGACY_DATA="${LEGACY_DATA}" S3_ID="${S3_ID}" S3_KEY="${S3_KEY}" \
STORES="${STORES}" EXTRA="${EXTRA}" SKIP_EXISTING="${SKIP_EXISTING}" REIMPORT="${REIMPORT}" \
S3_USER_FILES_BUCKET="${S3_USER_FILES_BUCKET}" S3_TEMPLATE_FILES_BUCKET="${S3_TEMPLATE_FILES_BUCKET}" \
S3_CHUNKS_BUCKET="${S3_CHUNKS_BUCKET}" S3_PROJECT_BLOBS_BUCKET="${S3_PROJECT_BLOBS_BUCKET}" \
python3 ./s3-import.py

# ── verification: object counts + sample MD5 readback ──────────────────────
log "verifying import..."
FAIL=0
S3_ENDPOINT="${S3_ENDPOINT}" LEGACY_DATA="${LEGACY_DATA}" STORES="${STORES}" \
S3_ID="${S3_ID}" S3_KEY="${S3_KEY}" \
S3_USER_FILES_BUCKET="${S3_USER_FILES_BUCKET}" S3_TEMPLATE_FILES_BUCKET="${S3_TEMPLATE_FILES_BUCKET}" \
S3_CHUNKS_BUCKET="${S3_CHUNKS_BUCKET}" S3_PROJECT_BLOBS_BUCKET="${S3_PROJECT_BLOBS_BUCKET}" OUTPUT_BUCKET="${OUTPUT_BUCKET}" \
python3 - <<'PY' || FAIL=1
import boto3, botocore.client, os, random, hashlib
env = os.environ
s3 = boto3.client("s3", endpoint_url=env["S3_ENDPOINT"].rstrip("/"),
    aws_access_key_id=env.get("S3_ID") or "x", aws_secret_access_key=env.get("S3_KEY") or "x",
    config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"), region_name="us-east-1")
legacy = env["LEGACY_DATA"]
stores = [s for s in env["STORES"].split(",") if s]

def bucket_of(store):
    return {
        "user_files": env["S3_USER_FILES_BUCKET"],
        "template_files": env["S3_TEMPLATE_FILES_BUCKET"],
        "overleaf-chunks": env["S3_CHUNKS_BUCKET"],
        "history/overleaf-chunks": env["S3_CHUNKS_BUCKET"],
        "overleaf-project-blobs": env["S3_PROJECT_BLOBS_BUCKET"],
        "history/overleaf-project-blobs": env["S3_PROJECT_BLOBS_BUCKET"],
        "output": env.get("OUTPUT_BUCKET", env["S3_USER_FILES_BUCKET"]),
    }[store]

def key_for(store, rel):
    if store in ("user_files", "template_files"):
        head, _, tail = rel.partition("/")
        if "_" in head:
            head = head.replace("_", "/", 1)
            return head if not tail else f"{head}/{tail}"
    return rel

def count(b):
    n, p = 0, {}
    while True:
        p = s3.list_objects_v2(Bucket=b, **({"ContinuationToken": p["NextContinuationToken"]} if p.get("NextContinuationToken") else {}))
        n += len(p.get("Contents", []))
        if not p.get("IsTruncated"):
            return n

errors = 0
for store in stores:
    root = os.path.join(legacy, store)
    if not os.path.isdir(root):
        continue
    local = []
    for r, _, fs in os.walk(root):
        for f in fs:
            local.append(os.path.join(r, f))
    if not local:
        print(f"  [ok ] {store}: 0 files (nothing to verify)")
        continue
    b = bucket_of(store)
    remote = count(b)
    ok = "ok " if remote >= len(local) else "FAIL"
    if remote < len(local):
        errors = 1
    print(f"  [{ok}] {store}: local={len(local)} s3://{b}={remote}")
    # sample MD5 readback (up to 3)
    for sample in random.sample(local, min(3, len(local))):
        rel = os.path.relpath(sample, root).replace(os.sep, "/")
        key = key_for(store, rel)
        lmd5 = hashlib.md5(open(sample, "rb").read()).hexdigest()
        try:
            body_md5 = hashlib.md5(s3.get_object(Bucket=b, Key=key)["Body"].read()).hexdigest()
        except Exception as e:
            print(f"        sample {key}: READ FAILED: {e}")
            errors = 1
            continue
        tag = "md5 match" if lmd5 == body_md5 else "MD5 MISMATCH"
        if lmd5 != body_md5:
            errors = 1
        print(f"        sample {key}: {tag}")
raise SystemExit(errors)
PY
[ "${FAIL}" -eq 0 ] && log "S3 import verified." || die "verification reported problems"
log "done."
