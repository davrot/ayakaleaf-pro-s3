#!/usr/bin/env python3
"""s3-import.py — upload the legacy Overleaf 6.2.0 filestore into the new
6.3.1 stack's S3 plane (SeaweedFS), using the OFFICIAL Overleaf key rules
(docs.overleaf.com/on-premises/maintenance/s3-migration):

  store (legacy /var/lib/overleaf/data/...)    bucket (env)                    key rule
  ─────────────────────────────────────────    ─────────────────────────────    ──────────────────────────────
  user_files/<project-id>_<file-id>            S3_USER_FILES_BUCKET      first "_" of the top-level
                                                        → <project-id>/<file-id>  path element becomes "/"
  template_files/...                           S3_TEMPLATE_FILES_BUCKET  same transform
  history/overleaf-chunks/...                  S3_CHUNKS_BUCKET          verbatim (layout already matches)
  history/overleaf-project-blobs/...           S3_PROJECT_BLOBS_BUCKET   verbatim
  (opt-in) output/...                          OUTPUT_BUCKET (opt-in)    verbatim
  (opt-in) *.zip exports                       S3_USER_FILES_BUCKET? → exports/<name>  (extra objects)

Env (required): S3_ENDPOINT, LEGACY_DATA
Env (buckets):  S3_USER_FILES_BUCKET, S3_TEMPLATE_FILES_BUCKET,
                S3_PROJECT_BLOBS_BUCKET, S3_CHUNKS_BUCKET, OUTPUT_BUCKET
Env (optional): S3_ID, S3_KEY, WORKERS (default 16), SKIP_EXISTING (0/1),
                REIMPORT (0/1), STORES (comma list), EXTRA (src=key;src=key)

Reads the legacy tree READ-ONLY. Verified afterwards by the calling shell.
"""
import boto3
import botocore.client
import hashlib
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

BOTO3_REQUIRED = True


def log(msg):
    print(f"[s3-import] {msg}", flush=True)


def md5file(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def bucket_objects(s3, bucket):
    p = {}
    while True:
        p = s3.list_objects_v2(Bucket=bucket, **({"ContinuationToken": p["NextContinuationToken"]} if p.get("NextContinuationToken") else {}))
        yield from p.get("Contents", [])
        if not p.get("IsTruncated"):
            break


def bucket_object_count(s3, bucket):
    return sum(1 for _ in bucket_objects(s3, bucket))


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.up = self.skip = self.err = self.bytes = 0
        self.done = self.total = 0

    def add(self, kind, nbytes=0):
        with self.lock:
            self.done += 1
            if kind == "up":
                self.up += 1
                self.bytes += nbytes
            elif kind == "skip":
                self.skip += 1
            else:
                self.err += 1

    def report(self):
        with self.lock:
            return f"{self.done}/{self.total} up={self.up} skip={self.skip} err={self.err} {self.bytes / (1 << 20):.0f}MiB"


def key_for(store, relpath):
    """Apply the official store→S3 key transform (relpath uses posix separators)."""
    if store in ("user_files", "template_files"):
        head, _, tail = relpath.partition("/")
        if "_" in head:
            head = head.replace("_", "/", 1)
            return head if not tail else f"{head}/{tail}"
        return relpath
    # history stores: legacy on-disk layout already equals the 6.3.1 S3 layout
    # (confirmed: reversed-project-id 3/3/18 + chunk/blob id, see
    #  sharelatex ProjectKey.js naiveReverse + official S3-migration guide
    #  "The history directories already have the correct layout").
    return relpath


def main():
    endpoint = os.environ["S3_ENDPOINT"].rstrip("/")
    legacy = os.environ["LEGACY_DATA"]
    skip_existing = os.environ.get("SKIP_EXISTING", "0") == "1"
    reimport = os.environ.get("REIMPORT", "0") == "1"
    workers = int(os.environ.get("WORKERS", "16"))
    stores = [s for s in os.environ.get("STORES", "").split(",") if s]
    extras = []
    for pair in os.environ.get("EXTRA", "").split(";"):
        if "=" in pair:
            src, key = pair.split("=", 1)
            extras.append((src.strip(), key.strip()))

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ.get("S3_ID") or "x",
        aws_secret_access_key=os.environ.get("S3_KEY") or "x",
        config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"),
        region_name="us-east-1",
    )
    s3.list_buckets()  # fail fast if the endpoint is unreachable

    def bucket_of(store):
        if store == "user_files":
            return os.environ.get("S3_USER_FILES_BUCKET", "overleaf-user-files")
        if store == "template_files":
            return os.environ.get("S3_TEMPLATE_FILES_BUCKET", "overleaf-template-files")
        if store in ("history/overleaf-chunks", "overleaf-chunks"):
            return os.environ.get("S3_CHUNKS_BUCKET", "overleaf-chunks")
        if store in ("history/overleaf-project-blobs", "overleaf-project-blobs"):
            return os.environ.get("S3_PROJECT_BLOBS_BUCKET", "overleaf-project-blobs")
        if store == "output":
            return os.environ.get("OUTPUT_BUCKET", "overleaf-user-files")
        raise ValueError(f"no bucket mapping for store {store}")

    log(f"endpoint={endpoint} stores={stores} reimport={reimport} skip_existing={skip_existing} workers={workers}")

    if not os.path.isdir(legacy):
        log(f"ERROR: legacy data root missing: {legacy}")
        return 2

    # ── collect work list ───────────────────────────────────────────────────
    jobs = []  # (bucket, key, src)
    for store in stores:
        root = os.path.join(legacy, store)
        if not os.path.isdir(root):
            log(f"store '{store}': not present in legacy data — skipped")
            continue
        n = 0
        bucket = bucket_of(store)
        for r, _dirs, files in os.walk(root):
            for f in files:
                src = os.path.join(r, f)
                rel = os.path.relpath(src, root).replace(os.sep, "/")
                jobs.append((bucket, key_for(store, rel), src))
                n += 1
        log(f"store '{store}': {n} files queued → s3://{bucket}")
    for src, key in extras:
        if os.path.isfile(src):
            jobs.append((os.environ.get("EXTRA_BUCKET", bucket_of("user_files")), key, src))
        else:
            log(f"extra '{src}': missing — skipped")
    stats = Stats()
    stats.total = len(jobs)
    t0 = time.time()
    if stats.total == 0:
        log("nothing to import (all stores empty/absent)")
        return 0

    # ── pre-flight: wipe (reimport) or ensure buckets exist ────────────────
    touched_buckets = sorted({b for b, _k, _s in jobs})
    for b in touched_buckets:
        if reimport:
            removed = 0
            for obj in list(bucket_objects(s3, b)):
                s3.delete_object(Bucket=b, Key=obj["Key"])
                removed += 1
            log(f"reimport: removed {removed} objects from '{b}'")
        else:
            try:
                s3.head_bucket(Bucket=b)
            except Exception:
                s3.create_bucket(Bucket=b)
                log(f"created bucket '{b}'")

    # ── upload ──────────────────────────────────────────────────────────────
    last = [0.0]

    def work(job):
        bucket, key, src = job
        try:
            size = os.path.getsize(src)
            if skip_existing:
                try:
                    head = s3.head_object(Bucket=bucket, Key=key)
                    etag = (head.get("ETag") or "").strip('"').lower()
                    if head.get("ContentLength") == size and etag == md5file(src):
                        stats.add("skip")
                        return
                except Exception:
                    pass
            s3.upload_file(src, bucket, key)
            stats.add("up", size)
        except Exception as e:
            stats.add("err")
            log(f"  ERROR {bucket}/{key}: {e}")
        now = time.time()
        if now - last[0] > 20:
            last[0] = now
            log(f"progress: {stats.report()}")

    with ThreadPoolExecutor(max_workers=workers) as ex:
        list(ex.map(work, jobs))

    # ── final counts ────────────────────────────────────────────────────────
    totals = {}
    for b in touched_buckets:
        totals[b] = bucket_object_count(s3, b)
        log(f"bucket '{b}' now holds {totals[b]} objects")
    log(f"done: {stats.report()} in {time.time() - t0:.1f}s")
    return 1 if stats.err else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ImportError as e:
        print(f"[s3-import] missing python module ({e}); run: pip install boto3", file=sys.stderr)
        sys.exit(3)
