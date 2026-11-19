#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# wipe-targets.sh — reset the TARGET plane to a blank slate (optional step;
# the import script already can reimport, use this to get a fully empty
# S3 plane before re-running the import).
#
#   deletes + recreates the overleaf S3 buckets (empty)
#
# All destructive actions require --yes. Nothing is rm -rf'd — buckets are
# recreated empty and the import re-uploads.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=./common.conf
. ./common.conf

YES=0; DRY_RUN=0
for a in "$@"; do case "$a" in
  --yes) YES=1 ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown flag: $a (try --help)" ;;
esac; done

require_cmd docker
require_cmd python3
python3 -c 'import boto3' 2>/dev/null || die "boto3 required for S3 wipe"
load_target_env

TS=$(date +%Y%m%d-%H%M%S)
echo "plan (ts=${TS}):"
echo "  s3 : delete + recreate buckets: ${S3_USER_FILES_BUCKET} ${S3_TEMPLATE_FILES_BUCKET} ${S3_PROJECT_BLOBS_BUCKET} ${S3_CHUNKS_BUCKET}"
if [ "${DRY_RUN}" -eq 1 ]; then log "dry-run: nothing done."; exit 0; fi
[ "${YES}" -eq 1 ] || die "refusing without --yes (destructive on the target plane)"

S3_ENDPOINT="${S3_ENDPOINT}" python3 - <<PY
import boto3, botocore.client, os
s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"].rstrip("/"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID") or "x",
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY") or "x",
    config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"),
    region_name="us-east-1")
for b in ["${S3_USER_FILES_BUCKET}", "${S3_TEMPLATE_FILES_BUCKET}", "${S3_PROJECT_BLOBS_BUCKET}", "${S3_CHUNKS_BUCKET}"]:
    n, p = 0, {}
    while True:
        p = s3.list_objects_v2(Bucket=b, **({"ContinuationToken": p["NextContinuationToken"]} if p.get("NextContinuationToken") else {}))
        for o in p.get("Contents", []):
            s3.delete_object(Bucket=b, Key=o["Key"]); n += 1
        if not p.get("IsTruncated"): break
    s3.delete_bucket(Bucket=b)
    s3.create_bucket(Bucket=b)
    print(f"[wipe-s3] {b}: deleted {n} objects, bucket recreated (empty)")
PY
log "S3 buckets wiped + recreated."
