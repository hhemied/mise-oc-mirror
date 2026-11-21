# Testing

## Static checks

```sh
shellcheck -x bin/* lib/utils.bash tests/*.sh
```

## End-to-end test

```sh
bash tests/smoke.sh
```

Needs `podman` (with a running machine on macOS) and network access to
`mirror.openshift.com`, `mise.run` and `github.com`. It starts a throwaway
Fedora container, mounts the repo read-only at `/work`, and runs
`tests/container.sh` inside. Nothing on the host's mise or asdf setup is
touched. A full run downloads four oc-mirror tarballs.

| Variable | Default | Meaning |
|----------|---------|---------|
| `TOOLS` | `mise asdf` | Which tools to test |
| `TEST_VERSION` | `4.20.0` | Version installed with the default tarball |
| `RHEL9_VERSION` | `4.19.0` | Version installed with the `rhel9` variant |
| `ASDF_VERSION` | `v0.20.2` | asdf release to test against |
| `CONTAINER_IMAGE` | `docker.io/library/fedora:42` | Must be `dnf`-based |

What it checks:

| Area | Checks |
|------|--------|
| macOS host only | `bin/download` refuses to run |
| Scripts directly | `list-all` is one space-separated line, has no pre-releases and nothing below the floor; `latest-stable` equals its last entry and that version's tarball exists; prefix query; pre-release listing and ordering; `OC_MIRROR_ARCH`; invalid arch, invalid variant, missing version and git refs fail with a clear message; a failed download leaves no files |
| mise | install with checksum, `exec`, `ls-remote`, `latest`, `variant = "rhel9"` install and run |
| asdf | `list all` with a filter, `latest` with and without a query, install with checksum, `exec`, shim created, `OC_MIRROR_VARIANT=rhel9` install |

Under asdf the working tree is copied into `~/.asdf/plugins/oc-mirror`
instead of using `asdf plugin add`, which clones from git and would test the
last commit rather than the files on disk.

Not covered: the checksum-mismatch path (it would need a fake mirror), the
`arch` override at install time, and the `ppc64le` / `s390x` binaries.

## Trying a change by hand

```sh
# mise
mise plugins link oc-mirror "$PWD"
mise cache clear oc-mirror
mise ls-remote oc-mirror

# any shell
bin/list-all
bin/latest-stable 4.20
```
