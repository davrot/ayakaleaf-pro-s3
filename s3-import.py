#!/usr/bin/env python3
"""s3-import.py — upload the legacy Overleaf 6.2.0 filestore into the new
6.3.1 stack's S3 plane (SeaweedFS), using the OFFICIAL Overleaf key rules
(docs.overleaf.com/on-premises/maintenance/s3-migration), then verify.

  store (legacy /var/lib/overleaf/data/...)    bucket (env)                    key rule
  ─────────────────────────────────────────    ─────────────────────────────    ──────────────────────────────
  user_files/<project-id>_<file-id>            S3_USER_FILES_BUCKET      first "_" of the top-level
                                                        → <project-id>/<file-id>  path element becomes "/"
  template_files/...                           S3_TEMPLATE_FILES_BUCKET  same transform
  history/overleaf-chunks/...                  S3_CHUNKS_BUCKET          verbatim (layout already matches)
  history/overleaf-project-blobs/...           S3_PROJECT_BLOBS_BUCKET   verbatim
  (opt-in) output/...                          OUTPUT_BUCKET             verbatim
  (opt-in) *.zip exports                        bucket of user_files    exports/<name>  (extra objects)

Usage:
  s3-import.py import    upload (default)
  s3-import.py verify    check per-store object counts + sample MD5 readback

Env (required): S3_ENDPOINT, LEGACY_DATA
Env (buckets):  S3_USER_FILES_BUCKET, S3_TEMPLATE_FILES_BUCKET,
                S3_PROJECT_BLOBS_BUCKET, S3_CHUNKS_BUCKET, OUTPUT_BUCKET
Env (optional): AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                WORKERS (default 16), SKIP_EXISTING (0/1), REIMPORT (0/1),
                STORES (comma list), EXTRA (src=key;src=key)
Reads the legacy tree READ-ONLY.
"""
import boto3
import botocore.client
import hashlib
import os
import random
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

BUCKET_MAP = {
    "user_files": "S3_USER_FILES_BUCKET",
    "template_files": "S3_TEMPLATE_FILES_BUCKET",
    "overleaf-chunks": "S3_CHUNKS_BUCKET",
    "history/overleaf-chunks": "S3_CHUNKS_BUCKET",
    "overleaf-project-blobs": "S3_PROJECT_BLOBS_BUCKET",
    "history/overleaf-project-blobs": "S3_PROJECT_BLOBS_BUCKET",
    "output": "OUTPUT_BUCKET",
}
BUCKET_DEFAULTS = {
    "user_files": "overleaf-user-files",
    "template_files": "overleaf-template-files",
    "overleaf-chunks": "overleaf-chunks",
    "history/overleaf-chunks": "overleaf-chunks",
    "overleaf-project-blobs": "overleaf-project-blobs",
    "history/overleaf-project-blobs": "overleaf-project-blobs",
    "output": "overleaf-user-files",
}


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


def bucket_of(store):
    env_key = BUCKET_MAP.get(store)
    if env_key is None:
        raise ValueError(f"no bucket mapping for store {store}")
    return os.environ.get(env_key, BUCKET_DEFAULTS[store])


def key_for(store, relpath):
    """Apply the official store→S3 key transform (relpath uses posix separators).

    user_files/template_files: first "_" of the top-level element → "/".
    History stores upload verbatim — the legacy on-disk layout already equals
    the 6.3.1 S3 layout (reversed-project-id 3/3/18 + chunk/blob id, see
    sharelatex ProjectKey.js naiveReverse and the official S3-migration
    guide: "The history directories already have the correct layout").
    """
    if store in ("user_files", "template_files"):
        head, _, tail = relpath.partition("/")
        if "_" in head:
            head = head.replace("_", "/", 1)
            return f"{head}/{tail}" if tail else head
    return relpath


def make_client():
    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["S3_ENDPOINT"].rstrip("/"),
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID") or "x",
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY") or "x",
        config=botocore.client.Config(s3={"addressing_style": "path"}, signature_version="s3v4"),
        region_name="us-east-1",
    )
    s3.list_buckets()  # fail fast if the endpoint is unreachable
    return s3


def bucket_objects(s3, bucket):
    p = {}
    while True:
        p = s3.list_objects_v2(Bucket=bucket, **({"ContinuationToken": p["NextContinuationToken"]} if p.get("NextContinuationToken") else {}))
        yield from p.get("Contents", [])
        if not p.get("IsTruncated"):
            break


def bucket_object_count(s3, bucket):
    return sum(1 for _ in bucket_objects(s3, bucket))


def stores():
    return [s for s in os.environ.get("STORES", "").split(",") if s]


def walk_store(store, legacy):
    """Yield (key, src) for every file in legacy/<store>."""
    root = os.path.join(legacy, store)
    if not os.path.isdir(root):
        return
    for r, _dirs, files in os.walk(root):
        for f in files:
            src = os.path.join(r, f)
            rel = os.path.relpath(src, root).replace(os.sep, "/")
            yield key_for(store, rel), src


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


def do_import(s3):
    legacy = os.environ["LEGACY_DATA"]
    skip_existing = os.environ.get("SKIP_EXISTING", "0") == "1"
    reimport = os.environ.get("REIMPORT", "0") == "1"
    workers = int(os.environ.get("WORKERS", "16"))

    # ── collect work list ───────────────────────────────────────────────────
    jobs = []  # (bucket, key, src)
    for store in stores():
        bucket = bucket_of(store)
        n = 0
        for key, src in walk_store(store, legacy):
            jobs.append((bucket, key, src))
            n += 1
        log(f"store '{store}': {n} files queued → s3://{bucket}" if n
            else f"store '{store}': absent or empty — skipped")
    for pair in os.environ.get("EXTRA", "").split(";"):
        if "=" in pair:
            src, key = pair.split("=", 1)
            if os.path.isfile(src):
                jobs.append((bucket_of("user_files"), key.strip(), src.strip()))
            else:
                log(f"extra '{src}': missing — skipped")
    stats = Stats()
    stats.total = len(jobs)
    if stats.total == 0:
        log("nothing to import (all stores empty/absent)")
        return 0
    log(f"endpoint={os.environ['S3_ENDPOINT'].rstrip('/')} reimport={reimport} skip_existing={skip_existing} workers={workers}")

    # ── pre-flight: wipe (reimport) or ensure buckets exist ────────────────
    for b in sorted({b for b, _k, _s in jobs}):
        if reimport:
            removed = 0
            for obj in bucket_objects(s3, b):
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
                    pass  # fall through: (re)upload
            s3.upload_file(src, bucket, key)
            stats.add("up", size)
        except Exception as e:
            stats.add("err")
            log(f"  ERROR {bucket}/{key}: {e}")
        now = time.time()
        if now - last[0] > 20:
            last[0] = now
            log(f"progress: {stats.report()}")

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=workers) as ex:
        list(ex.map(work, jobs))

    for b in sorted({b for b, _k, _s in jobs}):
        log(f"bucket '{b}' now holds {bucket_object_count(s3, b)} objects")
    log(f"done: {stats.report()} in {time.time() - t0:.1f}s")
    return 1 if stats.err else 0


def do_verify(s3):
    legacy = os.environ["LEGACY_DATA"]
    errors = 0
    for store in stores():
        local = list(walk_store(store, legacy))  # [(key, src), ...]
        if not local:
            print(f"  [ok ] {store}: 0 files (nothing to verify)")
            continue
        bucket = bucket_of(store)
        remote = bucket_object_count(s3, bucket)
        ok = remote >= len(local)
        print(f"  [{'ok ' if ok else 'FAIL'}] {store}: local={len(local)} s3://{bucket}={remote}")
        if not ok:
            errors = 1
        # sample MD5 readback (up to 3)
        for key, sample in random.sample(local, min(3, len(local))):
            lmd5 = md5file(sample)
            try:
                rmd5 = hashlib.md5(s3.get_object(Bucket=bucket, Key=key)["Body"].read()).hexdigest()
            except Exception as e:
                print(f"        sample {key}: READ FAILED: {e}")
                errors = 1
                continue
            match = lmd5 == rmd5
            if not match:
                errors = 1
            print(f"        sample {key}: {'md5 match' if match else 'MD5 MISMATCH'}")
    return errors


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "import"
    if mode not in ("import", "verify"):
        print(f"unknown mode {mode!r} (expected import|verify)", file=sys.stderr)
        return 2
    if "S3_ENDPOINT" not in os.environ or not os.environ.get("LEGACY_DATA"):
        print("S3_ENDPOINT and LEGACY_DATA env vars are required", file=sys.stderr)
        return 2
    s3 = make_client()
    return do_import(s3) if mode == "import" else do_verify(s3)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ImportError as e:
        print(f"[s3-import] missing python module ({e}); run: pip install boto3", file=sys.stderr)
        sys.exit(3)
