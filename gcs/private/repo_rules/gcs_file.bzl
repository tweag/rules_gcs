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

load("//gcs/private:util.bzl", "download_args", "have_unblocked_downloads", "parse_gs_url", "update_integrity_attr", "workspace_and_buildfile")

def _gcs_file_impl(repository_ctx):
    gs_url = repository_ctx.attr.url
    target = parse_gs_url(gs_url)
    repository_ctx.report_progress("Fetching {}".format(gs_url))

    # start download
    args = download_args(repository_ctx.attr, target["bucket_name"], target["remote_path"])
    waiter = repository_ctx.download(**args)
    download_info = waiter

    # populate BUILD files
    workspace_and_buildfile(repository_ctx, fallback_build_file_content = "exports_files(glob([\"**\"]))")
    rulename = "augmented_executable" if repository_ctx.attr.executable else "augmented_blob"
    build_file_content = """load("@rules_gcs//gcs/private/rules:augmented_blob.bzl", "{}")\n""".format(rulename)
    build_file_content += template_augmented(args["output"], target["remote_path"], repository_ctx.attr.executable)
    repository_ctx.file("file/BUILD.bazel", build_file_content)

    # wait for download to finish
    if have_unblocked_downloads():
        download_info = waiter.wait()
    return update_integrity_attr(repository_ctx, _gcs_file_attrs, download_info)

_gcs_file_doc = """Downloads a file from a GCS bucket and makes it available to be used as a file group.

Examples:
  Suppose you need to have a large file that is read during a test and is stored in a private bucket.
  This file is available from gs://my_org_assets/testdata.bin.
  Then you can add to your MODULE.bazel file:

  ```starlark
  gcs_file = use_repo_rule("@rules_gcs//gcs:repo_rules.bzl", "gcs_file")

  gcs_file(
      name = "my_testdata",
      url = "gs://my_org_assets/testdata.bin",
      sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  ```

  Targets would specify `@my_testdata//file` as a dependency to depend on this file."""

_gcs_file_attrs = {
    "build_file": attr.label(
        allow_single_file = True,
        doc =
            "The file to use as the BUILD file for this repository." +
            "This attribute is an absolute label (use '@//' for the main " +
            "repo). The file does not need to be named BUILD, but can " +
            "be (something like BUILD.new-repo-name may work well for " +
            "distinguishing it from the repository's actual BUILD files. " +
            "Either build_file or build_file_content can be specified, but " +
            "not both.",
    ),
    "build_file_content": attr.string(
        doc =
            "The content for the BUILD file for this repository. " +
            "Either build_file or build_file_content can be specified, but " +
            "not both.",
    ),
    "canonical_id": attr.string(
        doc = """A canonical ID of the file downloaded.

If specified and non-empty, Bazel will not take the file from cache, unless it
was added to the cache by a request with the same canonical ID.

If unspecified or empty, Bazel by default uses the URLs of the file as the
canonical ID. This helps catch the common mistake of updating the URLs without
also updating the hash, resulting in builds that succeed locally but fail on
machines without the file in the cache.
""",
    ),
    "downloaded_file_path": attr.string(
        doc = "Optional output path for the downloaded file. The remote path from the URL is used as a fallback.",
    ),
    "executable": attr.bool(
        doc = "If the downloaded file should be made executable.",
    ),
    "integrity": attr.string(
        doc = """Expected checksum in Subresource Integrity format of the file downloaded.

This must match the checksum of the file downloaded. It is a security risk
to omit the checksum as remote files can change. At best omitting this
field will make your build non-hermetic. It is optional to make development
easier but either this attribute or `sha256` should be set before shipping.""",
    ),
    "sha256": attr.string(
        doc = """The expected SHA-256 of the file downloaded.

This must match the SHA-256 of the file downloaded. _It is a security risk
to omit the SHA-256 as remote files can change._ At best omitting this
field will make your build non-hermetic. It is optional to make development
easier but should be set before shipping.""",
    ),
    "url": attr.string(
        mandatory = True,
        doc = "A URL to a file that will be made available to Bazel.\nThis must be a 'gs://' URL.",
    ),
}

gcs_file = repository_rule(
    implementation = _gcs_file_impl,
    attrs = _gcs_file_attrs,
    doc = _gcs_file_doc,
)

def template_augmented(local_path, remote_path, executable):
    rulename = "augmented_executable" if executable else "augmented_blob"
    template = """
{}(
    name = "file",
    local_path = "//:{}",
    remote_path = "{}",
    visibility = ["//visibility:public"],
)
"""
    return template.format(rulename, local_path, remote_path)
