#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-all.sh — full fs → S3 migration runbook for ONE legacy server.
#
# Order (per official guidance: stop writers first, consistent state):
#   1. preflight                    readonly
#   2. (optional) wipe-targets      blank-slate the target S3 buckets
#   3. import-s3 --reimport         legacy filestore/history → S3 buckets
#   4. verify                       automated + manual UI checklist
#
# Flags: --yes-all (runs destructive steps without interactive pause),
#        --wipe (blank-slate the S3 buckets first)
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=./common.conf
. ./common.conf

YES_ALL=0; WITH_WIPE=0; STEP="${STEP:-1}"
for a in "$@"; do case "$a" in
  --yes-all) YES_ALL=1 ;;
  --wipe) WITH_WIPE=1 ;;
  -h|--help) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown flag: $a (try --help)" ;;
esac; done

pause() {
  [ "${YES_ALL}" -eq 1 ] && return 0
  echo
  read -r -p "$1 [Enter to continue / 'abort' to stop] " ans
  case "${ans:-}" in abort*) die "aborted by user";; esac
}

step() { echo; echo "══ STEP $1 ══"; shift; "$@"; }

if [ "${STEP}" -le 1 ]; then
  step 1 ./preflight.sh
fi

if [ "${STEP}" -le 2 ] && [ "${WITH_WIPE}" -eq 1 ]; then
  pause "Wipe the target S3 buckets (deleted + recreated empty)?" && \
    step 2 ./wipe-targets.sh --yes
fi

if [ "${STEP}" -le 3 ]; then
  pause "Import the legacy filestore/history into S3 (--reimport)?"
  step 3 ./import-s3.sh --reimport
fi

if [ "${STEP}" -le 4 ]; then
  step 4 ./verify.sh
fi
log "runbook finished."
