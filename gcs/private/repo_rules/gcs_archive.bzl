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

load("//gcs/private:util.bzl", "bucket_url", "download_and_extract_args", "parse_gs_url")

def _gcs_archive_impl(repository_ctx):
    gs_url = repository_ctx.attr.url
    target = parse_gs_url(gs_url)
    repository_ctx.report_progress("Fetching {}".format(gs_url))

    # download && extract the repo
    args = download_and_extract_args(repository_ctx.attr, target["bucket_name"], target["remote_path"])
    repository_ctx.download_and_extract(**args)

    # apply patches after extraction has finished
    for patch in repository_ctx.attr.patches:
        repository_ctx.patch(patch, strip = repository_ctx.attr.patch_strip)

    # populate BUILD files
    has_build_file_content = len(repository_ctx.attr.build_file_content) > 0
    has_build_file_label = repository_ctx.attr.build_file != None
    if has_build_file_content and has_build_file_label:
        fail("must specify only one of \"build_file_content\" and \"build_file\"")
    if has_build_file_content:
        repository_ctx.file("BUILD.bazel", repository_ctx.attr.build_file_content)
    if has_build_file_label:
        repository_ctx.file("BUILD.bazel", repository_ctx.read(repository_ctx.attr.build_file))

_gcs_archive_doc = """Downloads a Bazel repository as a compressed archive file from a GCS bucket, decompresses it,
and makes its targets available for binding.

It supports the following file extensions: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`,
`"tar.gz"`, `"tgz"`, `"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `tar.bz2`, `"ar"`,
or `"deb"`.

Examples:
  Suppose your code depends on a private library packaged as a `.tar.gz`
  which is available from gs://my_org_code/libmagic.tar.gz. This `.tar.gz` file
  contains the following directory structure:

  ```
 MODULE.bazel
  src/
    magic.cc
    magic.h
  ```

  In the local repository, the user creates a `magic.BUILD` file which
  contains the following target definition:

  ```starlark
  cc_library(
      name = "lib",
      srcs = ["src/magic.cc"],
      hdrs = ["src/magic.h"],
  )
  ```

  Targets in the main repository can depend on this target if the
  following lines are added to `MODULE.bazel`:

  ```starlark
  gcs_archive = use_repo_rule("@rules_gcs//gcs:repo_rules.bzl", "gcs_archive")

  gcs_archive(
      name = "magic",
      url = "gs://my_org_code/libmagic.tar.gz",
      sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      build_file = "@//:magic.BUILD",
  )
  ```

  Then targets would specify `@magic//:lib` as a dependency.
"""

_gcs_archive_attrs = {
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
    "patch_strip": attr.int(
        default = 0,
        doc = "Strip the specified number of leading components from file names.",
    ),
    "patches": attr.label_list(
        doc =
            "A list of files that are to be applied as patches after " +
            "extracting the archive. It uses the Bazel-native patch implementation " +
            "which doesn't support fuzz match and binary patch.",
    ),
    "rename_files": attr.string_dict(
        doc =
            "An optional dict specifying files to rename during the extraction. " +
            "Archive entries with names exactly matching a key will be renamed to " +
            "the value, prior to any directory prefix adjustment. This can be used " +
            "to extract archives that contain non-Unicode filenames, or which have " +
            "files that would extract to the same path on case-insensitive filesystems.",
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
    "integrity": attr.string(
        doc = """Expected checksum in Subresource Integrity format of the file downloaded.

This must match the checksum of the file downloaded. It is a security risk
to omit the checksum as remote files can change. At best omitting this
field will make your build non-hermetic. It is optional to make development
easier but either this attribute or `sha256` should be set before shipping.""",
    ),
    "sha256": attr.string(
        doc = """The expected SHA-256 of the file downloaded.

This must match the SHA-256 of the file downloaded. It is a security risk
to omit the SHA-256 as remote files can change. At best omitting this
field will make your build non-hermetic. It is optional to make development
easier but either this attribute or `integrity` should be set before shipping.""",
    ),
    "strip_prefix": attr.string(
        doc = """A directory prefix to strip from the extracted files.

Many archives contain a top-level directory that contains all of the useful
files in archive. Instead of needing to specify this prefix over and over
in the `build_file`, this field can be used to strip it from all of the
extracted files.

For example, suppose you are using `foo-lib-latest.zip`, which contains the
directory `foo-lib-1.2.3/` under which there is a `WORKSPACE` file and are
`src/`, `lib/`, and `test/` directories that contain the actual code you
wish to build. Specify `strip_prefix = "foo-lib-1.2.3"` to use the
`foo-lib-1.2.3` directory as your top-level directory.

Note that if there are files outside of this directory, they will be
discarded and inaccessible (e.g., a top-level license file). This includes
files/directories that start with the prefix but are not in the directory
(e.g., `foo-lib-1.2.3.release-notes`). If the specified prefix does not
match a directory in the archive, Bazel will return an error.""",
    ),
    "type": attr.string(
        doc = """The archive type of the downloaded file.

By default, the archive type is determined from the file extension of the
URL. If the file has no extension, you can explicitly specify one of the
following: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`, `"tar.gz"`, `"tgz"`,
`"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `"tar.bz2"`, `"ar"`, or `"deb"`.""",
    ),
    "url": attr.string(
        mandatory = True,
        doc = "A URL to a file that will be made available to Bazel.\nThis must be a 'gs://' URL.",
    ),
}

gcs_archive = repository_rule(
    implementation = _gcs_archive_impl,
    attrs = _gcs_archive_attrs,
    doc = _gcs_archive_doc,
)
