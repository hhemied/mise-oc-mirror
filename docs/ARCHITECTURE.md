# Architecture

## One plugin, two tools

The plugin is a set of shell scripts that follow the
[asdf plugin contract](https://asdf-vm.com/plugins/create.html). mise runs the
same scripts through its
[asdf backend](https://mise.jdx.dev/asdf-legacy-plugins.html) and sets the same
`ASDF_*` variables, so there is a single code path. Rules that keep it
compatible with both:

- Read `ASDF_*` variables, never the `MISE_*` twins. The only mise-specific
  input is `MISE_TOOL_OPTS__<KEY>`, and each has a plain environment variable
  equivalent for asdf.
- `bin/list-all` prints one space-separated line. asdf splits on single
  spaces; mise accepts spaces or newlines.
- No `sort -V` (not portable, and it sorts pre-releases after the final
  release).
- Scripts never call `asdf` or `mise`.

## Files

| File | Called by | Does |
|------|-----------|------|
| `bin/list-all` | `ls-remote` / `list all`, version resolution | Prints installable versions, oldest first |
| `bin/latest-stable [query]` | `latest` | Prints the newest stable installable version, optionally within a prefix such as `4.20` |
| `bin/download` | `install`, first | Fetches the tarball, verifies SHA-256, leaves `$ASDF_DOWNLOAD_PATH/oc-mirror` |
| `bin/install` | `install`, second | Copies the binary to `$ASDF_INSTALL_PATH/bin/oc-mirror` |
| `lib/utils.bash` | sourced by all four | Architecture, variant, URLs, version listing |

Both tools shim everything in `$ASDF_INSTALL_PATH/bin` by default, so no
`list-bin-paths` script is needed.

## What "installable version" means

A version is listed only if `oc-mirror.tar.gz` exists for the architecture.
The mirror index lists every OpenShift release, with or without `oc-mirror`,
so `list_installable_versions` narrows it down:

1. Take every `X.Y.Z` (and `X.Y.Z-pre.N`) directory from
   `…/<arch>/clients/ocp/`.
2. Drop pre-releases unless `OC_MIRROR_INCLUDE_PRERELEASE=1`.
3. Drop minors below the architecture's floor (4.10 for `x86_64`, 4.14 for the
   others). The floor is hard-coded in `arch_floor`.
4. Find the ceiling: take the newest version of each minor, newest minor
   first, and send a `HEAD` request for its tarball until one exists. Drop all
   newer minors. This costs one request per minor that lacks `oc-mirror`,
   plus one.

`latest-stable` is the last stable line of that list, so `latest`, prefix
queries and the listing can never disagree.

The check is per minor, not per version: a few old pre-releases inside the
range have no tarball. They are hidden by default, and installing one fails
at download with a clear message.

## Install flow

```
bin/download
  refuse unless Linux, and unless install type is "version"
  resolve arch      MISE_TOOL_OPTS__ARCH    > OC_MIRROR_ARCH    > uname -m
  resolve tarball   MISE_TOOL_OPTS__VARIANT > OC_MIRROR_VARIANT > default
  curl <tarball> and sha256sum.txt into $ASDF_DOWNLOAD_PATH/.work
  compare SHA-256; abort on mismatch or if the file is not listed
  untar, move oc-mirror to $ASDF_DOWNLOAD_PATH/oc-mirror, delete .work

bin/install
  copy to $ASDF_INSTALL_PATH/bin/oc-mirror (mode 0755)
  run `oc-mirror --help`; on failure print a warning with the loader error
```

`bin/download` works inside the download directory rather than `/tmp`, because
`/tmp` is often a small tmpfs and the unpacked binary is over 300 MB. A failed
download leaves nothing behind.

Verification is SHA-256 against Red Hat's `sha256sum.txt`, fetched over HTTPS
from the same directory. The GPG signature (`sha256sum.txt.gpg`) is not
checked. Neither mise nor asdf verifies what an asdf-style plugin downloads,
and mise records only the version in `mise.lock`, so this check is the only
one.

## Inputs

| Variable | Set by | Used in |
|----------|--------|---------|
| `ASDF_INSTALL_VERSION`, `ASDF_INSTALL_TYPE` | asdf, mise | `download`, `install` |
| `ASDF_DOWNLOAD_PATH` | asdf, mise | `download`, `install` |
| `ASDF_INSTALL_PATH` | asdf, mise | `install` |
| `MISE_TOOL_OPTS__ARCH`, `MISE_TOOL_OPTS__VARIANT` | mise, from `[tools]` options | `download` |
| `OC_MIRROR_ARCH` | user | all scripts |
| `OC_MIRROR_VARIANT` | user | `download` |
| `OC_MIRROR_INCLUDE_PRERELEASE` | user | `list-all` |

mise passes tool options to `download` and `install` only, so under mise
`list-all` and `latest-stable` always list for the host architecture unless
`OC_MIRROR_ARCH` is set in the environment.
