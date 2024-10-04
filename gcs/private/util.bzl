"""
Copyright 2024 IMAX Corporation
Copyright 2024 Modus Create LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

load("//gcs/private:url_encoding.bzl", "url_encode")

def parse_gs_url(url):
    """
    Parses a URL of the form `gs://BUCKET_NAME/remote/path/to/object` into
    a dict with fields "bucket_name" and "remote_path".
    """
    if type(url) != type(""):
        fail("expected string, got {}".format(type(url)))
    if not url.startswith("gs://"):
        fail("expected URL with scheme 'gs', got {}".format(type(url)))
    bucket_name_and_remote_path = url.removeprefix("gs://")
    if not "/" in bucket_name_and_remote_path:
        fail("expected URL with format 'gs://BUCKET_NAME/remote/path/to/object'")
    (bucket_name, _, remote_path) = bucket_name_and_remote_path.partition("/")
    if len(bucket_name) == 0:
        fail("expected URL with non-empty bucket name")
    if len(remote_path) == 0:
        fail("expected URL with non-empty path")
    return {
        "bucket_name": bucket_name,
        "remote_path": remote_path,
    }

def repository_ctx_download_common_args(attr, bucket_name, remote_path):
    has_integrity = len(attr.integrity) > 0
    has_sha256 = len(attr.sha256) > 0
    if has_integrity == has_sha256:
        fail("expected exactly one of \"integrity\" and \"sha256\"")
    args = {
        "url": bucket_url(bucket_name, remote_path),
        "sha256": attr.sha256,
        "integrity": attr.integrity,
    }
    if len(attr.canonical_id) > 0:
        args.update({"canonical_id": attr.canonical_id})
    return args

def download_args(attr, bucket_name, remote_path):
    args = repository_ctx_download_common_args(attr, bucket_name, remote_path)
    output = attr.downloaded_file_path if attr.downloaded_file_path else remote_path
    args.update({
        "output": output,
        "executable": attr.executable,
        "block": False,
    })
    return args

def download_and_extract_args(attr, bucket_name, remote_path):
    args = repository_ctx_download_common_args(attr, bucket_name, remote_path)
    args.update({
        "type": attr.type,
        "stripPrefix": attr.strip_prefix,
        "rename_files": attr.rename_files,
    })
    return args

def bucket_url(bucket, object_path):
    return "https://storage.googleapis.com/{}/{}".format(bucket, url_encode(object_path))

def deps_from_file(module_ctx, lockfile_label):
    lockfile_path = module_ctx.path(lockfile_label)
    lockfile_content = module_ctx.read(lockfile_path)
    return parse_lockfile(lockfile_content)

def parse_lockfile(lockfile_content):
    lockfile = json.decode(lockfile_content)

    # the deps map should be a dict from local_path to object info
    if type(lockfile) != type({}):
        return fail("gcs_bucket.from_file expects a JSON file with a dict as the top-level - got {}".format(type(lockfile_content)))
    processed_lockfile = {}
    for (local_path, v) in lockfile.items():
        # we expect the following schema:
        # - exactly one of sha256 or integrity
        # - optionally a remote_path (if not, we populate it with the local_path instead)
        has_remote_path = "remote_path" in v
        has_integrity = "integrity" in v
        has_sha256 = "sha256" in v
        if has_integrity == has_sha256:
            fail("parsing gcs object with local path {}: expected exactly one of \"integrity\" and \"sha256\"".format(local_path))
        info = {
            "remote_path": v["remote_path"] if has_remote_path else local_path,
        }
        if has_integrity:
            info["integrity"] = v["integrity"]
        if has_sha256:
            info["sha256"] = v["sha256"]
        processed_lockfile[local_path] = info
    return processed_lockfile

def object_repo_name(bucket_name, remote_path):
    allowed_chars = \
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ" + \
        "abcdefghijklmnopqrstuvwxyz" + \
        "0123456789-._"
    cache = "o_" + bucket_name + "_" + url_encode(remote_path, escape = "_", unreserved = allowed_chars)
    return cache
