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
load("//gcs/private:util.bzl", "deps_from_file", "object_repo_name")
load("//gcs/private/repo_rules:eager.bzl", _eager = "eager")
load("//gcs/private/repo_rules:gcs_file.bzl", _gcs_file = "gcs_file")
load(
    "//gcs/private/repo_rules:hub_repo.bzl",
    _alias_hub_repo = "alias_hub_repo",
    _copy_hub_repo = "copy_hub_repo",
    _symlink_hub_repo = "symlink_hub_repo",
)

def _gcs_bucket_impl(module_ctx):
    blob_repos = {}
    hub_names_seen = {}
    root_module_direct_deps = []
    root_module_direct_dev_deps = []

    # collect all blob repos and hub repos
    for module in module_ctx.modules:
        for from_file in module.tags.from_file:
            if from_file.name in hub_names_seen:
                fail("duplicate module names \"{}\" in gcs_bucket.from_file".format(from_file.name))
            hub_names_seen[from_file.name] = True
            if from_file.dev_dependency:
                root_module_direct_dev_deps.append(from_file.name)
            else:
                root_module_direct_deps.append(from_file.name)
            deps = deps_from_file(module_ctx, from_file.lockfile)
            if from_file.method != "eager":
                for local_path, info in deps.items():
                    args = dep_to_blob_repo(from_file.bucket, local_path, info)
                    if args["name"] not in blob_repos:
                        blob_repos[args["name"]] = args
                    elif args != blob_repos[args["name"]]:
                        fail("the blob gs://{}/{} was requested twice with different arguments".format(from_file.bucket, info["remote_path"]))
            generate_hub_repo(from_file)

    # generate all requested blobs
    for args in blob_repos.values():
        _gcs_file(**args)
    return module_ctx.extension_metadata(
        root_module_direct_deps = root_module_direct_deps,
        root_module_direct_dev_deps = root_module_direct_dev_deps,
        reproducible = True,
    )

def dep_to_blob_repo(bucket_name, local_path, info):
    gs_url = "gs://{}/{}".format(bucket_name, info["remote_path"])
    return {
        "name": object_repo_name(bucket_name, info["remote_path"]),
        "downloaded_file_path": local_path,
        "executable": True,
        "sha256": info["sha256"] if "sha256" in info else None,
        "integrity": info["integrity"] if "integrity" in info else None,
        "url": gs_url,
    }

def generate_hub_repo(from_file_tag):
    if from_file_tag.method == "symlink":
        generator = _symlink_hub_repo
    elif from_file_tag.method == "alias":
        generator = _alias_hub_repo
    elif from_file_tag.method == "copy":
        generator = _copy_hub_repo
    elif from_file_tag.method == "eager":
        generator = _eager
    else:
        fail("from_file method {} is not yet implemented".format(from_file_tag.method))
    generator(
        name = from_file_tag.name,
        lockfile = from_file_tag.lockfile,
        bucket = from_file_tag.bucket,
    )

_gcs_bucket_doc = """Downloads a collection of objects from a GCS bucket and makes them available under a single hub repository name.

Examples:
  Suppose your code depends on a collection of large assets that are used during code generation or testing. Those assets are stored in a private gcs bucket `gs://my_org_assets`.

  In the local repository, the user creates a `gcs_lock.json` JSON lockfile describing the required objects, including their expected hashes:

  ```json
    {
        "trainingdata/model/small.bin": {
            "sha256": "abd83816bd236b266c3643e6c852b446f068fe260f3296af1a25b550854ec7e5"
        },
        "trainingdata/model/medium.bin": {
            "sha256": "c6f9568f930b16101089f1036677bb15a3185e9ed9b8dbce2f518fb5a52b6787"
        },
        "trainingdata/model/large.bin": {
            "sha256": "b3ccb0ba6f7972074b0a1e13340307abfd5a5eef540c521a88b368891ec5cd6b"
        },
        "trainingdata/model/very_large.bin": {
            "remote_path": "weird/nested/path/extra/model/very_large.bin",
            "integrity": "sha256-Oibw8PV3cDY84HKv3sAWIEuk+R2s8Hwhvlg6qg4H7uY="
        }
    }
  ```

  The exact format for the lockfile is a JSON object where each key is a path to a local file in the repository and the value is a JSON object with the following keys:

  - `sha256`: the expected sha256 hash of the file. Required unless `integrity` is used.
  - `integrity`: the expected SRI value of the file. Required unless `sha256` is used.
  - `remote_path`: name of the object within the bucket. If not set, the local path is used.

  Targets in the main repository can depend on this target if the
  following lines are added to `MODULE.bazel`:

  ```starlark
  gcs_bucket = use_extension("@rules_gcs//gcs:extensions.bzl", "gcs_bucket")
  gcs_bucket.from_file(
      name = "trainingdata",
      bucket = "my_org_assets",
      lockfile = "@//:gcs_lock.json",
  )
  ```

  Then targets would specify labels like `@trainingdata//:trainingdata/model/very_large.bin` as a dependency.
"""

_from_file_attrs = {
    "name": attr.string(
        doc = "Name of the hub repository containing referencing all blobs",
        mandatory = True,
    ),
    "bucket": attr.string(
        doc = "Name of the GCS bucket",
        mandatory = True,
    ),
    "lockfile": attr.label(
        doc = "JSON lockfile containing objects to load from the GCS bucket",
        mandatory = True,
    ),
    "method": attr.string(
        doc = """Method used for downloading:

`symlink`: lazy fetching with symlinks,
`alias`: lazy fetching with alias targets,
`copy`: lazy fetching with full file copies,
`eager`: all objects are fetched eagerly""",
        values = ["symlink", "alias", "copy", "eager"],
        default = "symlink",
    ),
    "dev_dependency": attr.bool(
        doc = "If true, this dependency will be ignored if the current module is not the root module or `--ignore_dev_dependency` is enabled.",
    ),
}

_from_file_tag = tag_class(
    attrs = _from_file_attrs,
)

gcs_bucket = module_extension(
    implementation = _gcs_bucket_impl,
    tag_classes = {
        "from_file": _from_file_tag,
    },
    doc = _gcs_bucket_doc,
)
