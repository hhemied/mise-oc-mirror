# mise-oc-mirror

A plugin for [mise](https://mise.jdx.dev) and [asdf](https://asdf-vm.com) that
installs Red Hat's [`oc-mirror`](https://github.com/openshift/oc-mirror) binary
from the official OpenShift mirror:

```
https://mirror.openshift.com/pub/openshift-v4/<arch>/clients/ocp/<version>/oc-mirror.tar.gz
```

Every download is checked against the SHA-256 in that directory's
`sha256sum.txt`.

## Requirements

- **Linux.** Red Hat publishes `oc-mirror` as a Linux binary only. On macOS
  the install stops with an error; use a Linux VM or container.
- `bash`, `curl`, `tar`, `awk`, `sed`, `grep`, `sort`, and `sha256sum` or `shasum`.
- `libgpgme.so.11` at run time (both build variants link against it):

  | Distro | Package |
  |--------|---------|
  | Fedora / RHEL / CentOS Stream | `dnf install gpgme` |
  | Debian / Ubuntu | `apt install libgpgme11` (name varies by release) |

## Install with mise

```toml
# mise.toml
[plugins]
oc-mirror = "https://github.com/hhemied/mise-oc-mirror#989ec100ee8ab635fe760cea0f14737056a94adf"

[tools]
oc-mirror = "4.20.0"
```

Pin a full commit SHA from this repo (mise rejects abbreviated ones); the
one above is the first release.

```sh
mise install
mise exec -- oc-mirror version
```

For local development point the plugin at a checkout instead:
`oc-mirror = "/absolute/path/to/mise-oc-mirror"`.

## mise without a plugin

mise can also install `oc-mirror` with its built-in
[`http` backend](https://mise.jdx.dev/dev-tools/backends/http.html), with no
plugin at all. mise then downloads and verifies the file itself and records
the URL and checksum in `mise.lock`.

```toml
# mise.toml
[tools."http:oc-mirror"]
version = "latest"
postinstall = "chmod +x \"$MISE_TOOL_INSTALL_PATH/oc-mirror\""
version_list_url = "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
version_regex = 'href="(\d+\.\d+\.\d+)/"'
version_expr = 'sortVersions(filter(versions, int(split(#, ".")[0]) == 4 && int(split(#, ".")[1]) >= 14))'

[tools."http:oc-mirror".platforms]
linux-x64 = { url = "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/{{ version }}/oc-mirror.tar.gz", checksum_url = "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/{{ version }}/sha256sum.txt" }
linux-arm64 = { url = "https://mirror.openshift.com/pub/openshift-v4/aarch64/clients/ocp/{{ version }}/oc-mirror.tar.gz", checksum_url = "https://mirror.openshift.com/pub/openshift-v4/aarch64/clients/ocp/{{ version }}/sha256sum.txt" }
```

The tool is then named `http:oc-mirror` (`mise ls-remote http:oc-mirror`).
The `postinstall` line is needed because Red Hat's tarball stores the binary
without the executable bit.

Compared with the plugin, this has fixed rules where the plugin checks the
mirror:

| | Plugin | `http` backend |
|---|--------|----------------|
| Versions listed | Whatever ships `oc-mirror` for the host architecture | 4.14 and later 4.y releases; edit `version_expr` when a 5.y release ships `oc-mirror` |
| `x86_64` 4.10 – 4.13 | Listed | Not listed |
| `rhel9` variant | `variant = "rhel9"` | Change the file name in both `url` values |
| `ppc64le`, `s390x` | Supported | Not supported by mise's platform keys |
| `mise.lock` | Version only | Version, URL and checksum |
| Works with asdf | Yes | No |

## Install with asdf

```sh
asdf plugin add oc-mirror https://github.com/hhemied/mise-oc-mirror.git
asdf install oc-mirror 4.20.0
asdf set oc-mirror 4.20.0
oc-mirror version
```

## Versions

```sh
mise ls-remote oc-mirror        # or: asdf list all oc-mirror
mise latest oc-mirror           # or: asdf latest oc-mirror
mise use oc-mirror@latest
mise use oc-mirror@4.20         # newest 4.20.z
```

Only versions that actually ship `oc-mirror` are listed:

| Architecture | First minor with `oc-mirror.tar.gz` |
|--------------|-------------------------------------|
| `x86_64` | 4.10 |
| `aarch64`, `ppc64le`, `s390x` | 4.14 |

Newer OpenShift lines that do not ship `oc-mirror` are left out
automatically, so `latest` always resolves to a version that can be installed.
At the time of writing that is 4.22.z, because the 5.0.z directories contain no
`oc-mirror` tarball.

Pre-releases (`-rc.N`, `-ec.N`) are hidden by default. Set
`OC_MIRROR_INCLUDE_PRERELEASE=1` to list them, or install one by its exact
version. Some old pre-releases have no tarball and fail at download.

## Options

| Purpose | mise (`[tools]` option) | asdf / any shell | Values |
|---------|-------------------------|------------------|--------|
| Build variant | `variant = "rhel9"` | `OC_MIRROR_VARIANT=rhel9` | `default` (`oc-mirror.tar.gz`), `rhel9` (`oc-mirror.rhel9.tar.gz`) |
| Architecture | `arch = "x86_64"` | `OC_MIRROR_ARCH=x86_64` | `x86_64`, `aarch64`, `ppc64le`, `s390x` (default: host) |
| List pre-releases | — | `OC_MIRROR_INCLUDE_PRERELEASE=1` | `0`, `1` |

```toml
[tools]
oc-mirror = { version = "4.20.0", variant = "rhel9" }
```

```sh
OC_MIRROR_VARIANT=rhel9 asdf install oc-mirror 4.20.0
```

The `rhel9` variant is Red Hat's build for RHEL 9. It exists from 4.16.0
onward and for later 4.15.z releases; where it is missing the install fails
with the URL it tried. A version has one install directory, so installing the
other variant of an already installed version needs a reinstall
(`mise install --force`, or `asdf uninstall` first).

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `not supported on macOS` | Expected: Linux only. |
| `failed to download …` | That version, architecture or variant is not on the mirror. Open the printed directory URL to see what exists. |
| `checksum mismatch` | The download does not match Red Hat's `sha256sum.txt`. Retry; if it persists, do not use the file. |
| `libgpgme.so.11: cannot open shared object file` | Install `gpgme` (see Requirements). |
| A new version is missing from `mise ls-remote` | mise caches the list: `mise cache clear oc-mirror`. |

## Development

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/TESTING.md](docs/TESTING.md).

## Author

Hazem Hemied <hazem.hemied@gmail.com>

## License

The plugin scripts are MIT-licensed (see [LICENSE](LICENSE)). The `oc-mirror`
binary is distributed by Red Hat under its own terms.
