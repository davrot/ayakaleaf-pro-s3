#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# import-s3.sh — import the legacy 6.2.0 filestore into the new S3 plane
# (SeaweedFS buckets), per the official Overleaf fs→S3 migration rules, then
# verify (object counts + sample MD5 readback).
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
  -h|--help) sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown flag: $a (try --help)" ;;
esac; done

require_cmd python3
python3 -c 'import boto3' 2>/dev/null || die "python3 + boto3 required (pip install boto3)"
require_container "${TARGET_SEAWEEDFS_S3_CONTAINER}"

LEGACY_DATA="${LEGACY_SERVER_DATA}/data"
[ -d "${LEGACY_DATA}" ] || die "legacy filestore data root not found: ${LEGACY_DATA} (LEGACY_SERVER_DATA=${LEGACY_SERVER_DATA})"

# AWS credentials + bucket names come from the target .env (already exported).
load_target_env

STORES="user_files,template_files"
[ -d "${LEGACY_DATA}/history/overleaf-chunks" ]        && STORES="${STORES},history/overleaf-chunks"
[ -d "${LEGACY_DATA}/history/overleaf-project-blobs" ] && STORES="${STORES},history/overleaf-project-blobs"
[ "${WITH_EPHEMERAL}" -eq 1 ] && [ -d "${LEGACY_DATA}/output" ] && STORES="${STORES},output"

log "target S3     : ${S3_ENDPOINT}"
log "legacy data   : ${LEGACY_DATA}"
for s in ${STORES//,/ }; do
  if [ -d "${LEGACY_DATA}/${s}" ]; then
    NF=$(find "${LEGACY_DATA}/${s}" -type f 2>/dev/null | wc -l | tr -d ' ')
    SZ=$(du -sh "${LEGACY_DATA}/${s}" 2>/dev/null | cut -f1)
    [ "${NF}" -gt 0 ] && log "  ${s}: ${NF} files (${SZ})" || log "  ${s}: (0 files — will be skipped)"
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
  [ -n "${EXTRA}" ] && log "extra objects : $(echo "${EXTRA}" | tr ';' '\n' | wc -l) legacy export zip(s)"
fi
log "reimport? ${REIMPORT}   skip-existing? ${SKIP_EXISTING}"

if [ "${DRY_RUN}" -eq 1 ]; then log "dry-run: nothing was changed."; exit 0; fi

export LEGACY_DATA STORES EXTRA REIMPORT SKIP_EXISTING
python3 ./s3-import.py import
log "verifying import..."
python3 ./s3-import.py verify || die "post-import verification reported problems"
log "done."
