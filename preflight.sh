#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# preflight.sh — READONLY health check of everything needed for the migration.
# Safe to run any number of times; changes nothing.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=./common.conf
. ./common.conf

require_cmd docker

FAIL=0
ok()   { echo "  [ok  ] $*"; }
warn() { echo "  [WARN] $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

echo "══ legacy backup (source, READONLY) ══"
[ -d "${LEGACY_ROOT}" ] && ok "LEGACY_ROOT: ${LEGACY_ROOT}" || bad "LEGACY_ROOT missing: ${LEGACY_ROOT}"
[ -d "${LEGACY_SERVER_DATA}/data" ] && ok "filestore data dir present" || bad "filestore data dir missing: ${LEGACY_SERVER_DATA}/data"
if [ -d "${LEGACY_SERVER_DATA}/data" ]; then
  for s in user_files template_files history/overleaf-chunks history/overleaf-project-blobs output; do
    d="${LEGACY_SERVER_DATA}/data/${s}"
    if [ -d "${d}" ]; then
      NF=$(find "${d}" -type f 2>/dev/null | wc -l | tr -d ' ')
      SZ=$(du -sh "${d}" 2>/dev/null | cut -f1)
      [ "${NF}" -gt 0 ] && ok "store ${s}: ${NF} files (${SZ})" || warn "store ${s}: present but EMPTY (nothing to import from it)"
    else
      warn "store ${s}: absent in this legacy backup"
    fi
  done
  ZIPS=$(find "${LEGACY_SERVER_DATA}" -maxdepth 1 -name '*.zip' 2>/dev/null | wc -l | tr -d ' ')
  [ "${ZIPS}" -gt 0 ] && warn "${ZIPS} legacy export zip(s) present (import only with --with-exports)"
fi
[ -f "${LEGACY_ROOT}/.env" ] && ok "legacy .env present" || warn "legacy .env missing (needed for config diff below)"

echo
echo "══ target stack (this machine) ══"
for c in "${TARGET_OVERLEAF_CONTAINER}" "${TARGET_SEAWEEDFS_S3_CONTAINER}"; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$c" 2>/dev/null || echo -)
  [ "${st}" = "running" ] && ok "container ${c}: running (health: ${h})" || bad "container ${c}: ${st}"
done
net=$(docker network inspect overleaf-network -f '{{.Driver}}' 2>/dev/null || echo missing)
[ "${net}" = "bridge" ] && ok "overleaf-network present" || bad "overleaf-network missing"

echo
echo "══ S3 plane ══"
load_target_env
if df -h "${TARGET_COMPOSE_DIR}" | tail -1 | grep -q .; then
  df -h "${TARGET_COMPOSE_DIR}" | tail -1
fi
if python3 -c 'import boto3' 2>/dev/null; then
  S3_ENDPOINT="${S3_ENDPOINT}" AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" python3 - <<'PY' && ok "boto3 can reach the S3 endpoint" || bad "S3 endpoint unreachable with target .env credentials"
import boto3, botocore.client, os, sys
s3 = boto3.client("s3", endpoint_url=os.environ["S3_ENDPOINT"].rstrip("/"),
    aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID") or "x",
    aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY") or "x",
    config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"), region_name="us-east-1")
s3.list_buckets()
PY
  for b in "${S3_USER_FILES_BUCKET}" "${S3_TEMPLATE_FILES_BUCKET}" "${S3_PROJECT_BLOBS_BUCKET}" "${S3_CHUNKS_BUCKET}"; do
    S3_ENDPOINT="${S3_ENDPOINT}" python3 -c "
import boto3, botocore.client, os, sys
BUCKET = '${b}'
s3 = boto3.client('s3', endpoint_url=os.environ['S3_ENDPOINT'].rstrip('/'),
    aws_access_key_id=os.environ.get('AWS_ACCESS_KEY_ID') or 'x',
    aws_secret_access_key=os.environ.get('AWS_SECRET_ACCESS_KEY') or 'x',
    config=botocore.client.Config(s3={'addressing_style': 'path'}, signature_version='s3v4'), region_name='us-east-1')
n = 0
try:
    p = {}
    while True:
        p = s3.list_objects_v2(Bucket=BUCKET, **({'ContinuationToken': p['NextContinuationToken']} if p.get('NextContinuationToken') else {}))
        n += len(p.get('Contents', []))
        if not p.get('IsTruncated'): break
    print(f'  [ok  ] bucket {BUCKET}: {n} objects (reachable)')
except Exception as e:
    print(f'  [FAIL] bucket {BUCKET}: ' + str(e)); sys.exit(1)
" || FAIL=1
  done
else
  warn "python3+boto3 not available (needed by import-s3.sh)"
fi

echo
echo "══ legacy inline-compose values (not in .env) — invite token & third-party clients ══"
if [ -f "${LEGACY_SERVER_DATA:-x}/../compose.yaml" ] || [ -f "${LEGACY_ROOT}/overleafserver/compose.yaml" ]; then
  LC="${LEGACY_ROOT}/overleafserver/compose.yaml"
  for k in OVERLEAF_INVITE_TOKEN_SECRET ZOTERO_CLIENT_KEY GITHUB_SYNC_CLIENT_ID; do
    lv=$(grep -oP "^\s*${k}:\s*\K\S+" "${LC}" 2>/dev/null | head -1 || true)
    tv="${!k:-}"
    if [ -n "${lv}" ] && [ "${lv}" = "${tv}" ]; then
      echo "  [same] ${k} (legacy inline == target .env)"
    elif [ -n "${lv}" ]; then
      echo "  [DIFF] ${k}: legacy-compose=${lv:0:10} | target=${tv:0:10}"
    else
      echo "  [note] ${k}: not set inline in legacy compose"
    fi
  done
fi

echo
echo "══ config diff (legacy .env vs target .env) — decisions to confirm ══"
if [ -f "${LEGACY_ROOT}/.env" ]; then
  python3 - "${LEGACY_ROOT}/.env" "${TARGET_COMPOSE_DIR}/.env" <<'PY'
import re, sys
def parse(p):
    d = {}
    for line in open(p, encoding="utf-8", errors="replace"):
        m = re.match(r'^\s*([A-Z0-9_]+)\s*=\s*(.*)$', line)
        if m and not line.strip().startswith("#"):
            d[m.group(1)] = m.group(2).strip().strip("'\"")
    return d
old = parse(sys.argv[1]); new = parse(sys.argv[2])
keys = sorted(set(k for k in old.keys() | new.keys() if k not in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")))
def redact(v): return ((v[:6] + "…" + v[-4:]) if len(v) > 12 else (("(set)") if v else "(unset)")) if v is not None else "(absent)"
for k in keys:
    o, n = old.get(k), new.get(k)
    if o == n:
        if o is not None: print(f"  [same] {k}")
    else:
        print(f"  [DIFF] {k}: legacy={redact(o)} | target={redact(n)}")
PY
  warn "review the [DIFF] lines above: OIDC client, zotero/github credentials, invite token, site name."
  log "  (secrets shown truncated)"
fi

echo
if [ "${FAIL}" -eq 1 ]; then log "PREFLIGHT FAILED (see [FAIL] lines)"; exit 1; fi
log "preflight OK — safe to proceed (tools are still idempotent; all destructive steps need explicit --yes)."
