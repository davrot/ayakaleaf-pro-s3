#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# verify.sh — post-import verification (mostly automated checks + a manual
# UI checklist to run by a human with a browser).
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=./common.conf
. ./common.conf

require_cmd docker
load_target_env
FAIL=0
ok()   { echo "  [ok  ] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

echo "══ service health ══"
for c in "${TARGET_OVERLEAF_CONTAINER}" "${TARGET_SEAWEEDFS_S3_CONTAINER}"; do
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$c" 2>/dev/null || echo missing)
  [ "${h}" = "healthy" ] || [ "${h}" = "running" ] && ok "${c}: ${h}" || bad "${c}: ${h}"
done

echo
echo "══ S3 objects ══"
if python3 -c 'import boto3' 2>/dev/null; then
  S3_ENDPOINT="${S3_ENDPOINT}" python3 - <<'PY'
import boto3, botocore.client, os
s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"].rstrip("/"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID") or "x",
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY") or "x",
    config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"), region_name="us-east-1")
buckets = [os.environ.get("S3_USER_FILES_BUCKET","overleaf-user-files"), os.environ.get("S3_TEMPLATE_FILES_BUCKET","overleaf-template-files"), os.environ.get("S3_PROJECT_BLOBS_BUCKET","overleaf-project-blobs"), os.environ.get("S3_CHUNKS_BUCKET","overleaf-chunks")]
for b in buckets:
    try:
        n, p = 0, {}
        while True:
            p = s3.list_objects_v2(Bucket=b, **({"ContinuationToken": p["NextContinuationToken"]} if p.get("NextContinuationToken") else {}))
            n += len(p.get("Contents", []))
            if not p.get("IsTruncated"): break
        print(f"  [ok  ] s3://{b}: {n} objects")
    except Exception as e:
        print(f"  [FAIL] s3://{b}: {e}")
PY
else
  echo "  (boto3 not installed — skipped)"
fi

echo
echo "══ app HTTP ══"
HTTP=$(docker exec "${TARGET_OVERLEAF_CONTAINER}" curl -fsI --connect-timeout 5 http://localhost 2>/dev/null | head -1 || echo "no-response")
case "${HTTP}" in *200*) ok "overleaf app answers HTTP 200" ;; *) bad "overleaf app did not answer HTTP 200 (${HTTP})" ;; esac

echo
echo "══ MANUAL UI CHECKLIST (run from a browser) ══"
cat <<'CHK'
  1. OIDC login works (admin account) — cookies/secure flags fine
  2. project list shows the legacy projects; open one: all files visible
  3. binary file preview works (image inside a project)
  4. compile a project: PDF builds; images render in the PDF; png2pdf ok
  5. history panel: legacy snapshots are listed AND render a snapshot
       ← proves the overleaf-chunks import (the big one)
  6. upload a NEW file: it appears AND lands in s3://overleaf-user-files
       (aws s3 ls s3://overleaf-user-files --endpoint-url http://localhost:8333)
  7. a pre-migration invite link (from the old server) still verifies —
       proves OVERLEAF_INVITE_TOKEN_SECRET continuity
  8. GitHub-sync + Zotero integrations still authenticate (client creds!)
  9. admin: create user / create project smoke test
CHK

[ "${FAIL}" -eq 0 ] || { log "VERIFICATION FAILED (see [FAIL] lines)"; exit 1; }
log "automated verification OK — now walk the manual checklist."
