#!/usr/bin/env bash
# lib/utils.bash — helpers shared by the bin/ scripts.
#
# The plugin follows the asdf plugin contract and reads only ASDF_* variables.
# mise sets the same ASDF_* names (plus MISE_* twins), so one code path serves
# both tools.

MIRROR_BASE="https://mirror.openshift.com/pub/openshift-v4"
# shellcheck disable=SC2034  # used by the scripts that source this file
TOOL_NAME="oc-mirror"

fail() {
  printf 'oc-mirror plugin: ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf 'oc-mirror plugin: %s\n' "$*" >&2
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command '${cmd}' not found in PATH"
  done
}

# oc-mirror is published as a Linux ELF only.
require_linux() {
  local os
  os="$(uname -s)"
  case "${os}" in
    Linux) ;;
    Darwin) fail "oc-mirror is not supported on macOS: Red Hat publishes Linux binaries only. Use a Linux VM or container." ;;
    *) fail "oc-mirror is not supported on ${os}: Red Hat publishes Linux binaries only." ;;
  esac
}

# Mirror path segment for the target architecture.
# Override: `arch` tool option in mise (MISE_TOOL_OPTS__ARCH) or OC_MIRROR_ARCH.
resolve_arch() {
  local raw="${MISE_TOOL_OPTS__ARCH:-${OC_MIRROR_ARCH:-$(uname -m)}}"
  case "${raw}" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    ppc64le) printf 'ppc64le\n' ;;
    s390x) printf 's390x\n' ;;
    *) fail "unsupported architecture '${raw}' (supported: x86_64, aarch64, ppc64le, s390x)" ;;
  esac
}

# Tarball file name for the requested build variant.
# Override: `variant` tool option in mise (MISE_TOOL_OPTS__VARIANT) or
# OC_MIRROR_VARIANT. Empty or "default" selects Red Hat's default build.
resolve_tarball_name() {
  local variant="${MISE_TOOL_OPTS__VARIANT:-${OC_MIRROR_VARIANT:-default}}"
  case "${variant}" in
    default) printf 'oc-mirror.tar.gz\n' ;;
    rhel9) printf 'oc-mirror.rhel9.tar.gz\n' ;;
    *) fail "unsupported variant '${variant}' (supported: default, rhel9)" ;;
  esac
}

# version_dir_url <arch> <version>
version_dir_url() {
  printf '%s/%s/clients/ocp/%s\n' "${MIRROR_BASE}" "$1" "$2"
}

# url_exists <url> — 0 if the mirror has the file, 1 if it does not.
# Anything other than a clear yes/no aborts, so a network problem is never
# mistaken for "this version has no oc-mirror".
url_exists() {
  local code
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --retry 2 "$1")" || code="000"
  case "${code}" in
    200) return 0 ;;
    403 | 404) return 1 ;;
    *) fail "could not check $1 (HTTP ${code})" ;;
  esac
}

# Oldest OpenShift minor that ships oc-mirror.tar.gz for an architecture.
# Prints "<major> <minor>".
arch_floor() {
  case "$1" in
    x86_64) printf '4 10\n' ;;
    *) printf '4 14\n' ;;
  esac
}

# Sort versions oldest first, with pre-releases (4.20.0-rc.1) before their
# final release (4.20.0). Avoids `sort -V`, which is not portable and puts
# pre-releases after the final release.
sort_versions() {
  awk '{
    v = $0; base = v; pre = ""
    i = index(v, "-")
    if (i > 0) { base = substr(v, 1, i - 1); pre = substr(v, i + 1) }
    split(base, b, ".")
    stable = 1; kind = "-"; n = 0
    if (pre != "") { stable = 0; split(pre, p, "."); kind = p[1]; n = p[2] + 0 }
    printf "%d %d %d %d %s %d %s\n", b[1], b[2], b[3], stable, kind, n, v
  }' | LC_ALL=C sort -k1,1n -k2,2n -k3,3n -k4,4n -k5,5 -k6,6n | awk '{ print $7 }'
}

# list_installable_versions <arch> <include_prerelease: 0|1>
#
# Prints, one per line and oldest first, the versions that have an
# oc-mirror tarball for <arch>:
#   1. every version directory in the arch's mirror index,
#   2. minus pre-releases unless requested,
#   3. minus minors older than the arch's floor,
#   4. minus the newest minors that do not ship oc-mirror (found by probing
#      the newest version of each minor, newest minor first, until one has
#      the tarball).
list_installable_versions() {
  local arch="$1" include_pre="$2"
  local index_url index versions floor_major floor_minor minors minor newest ceiling=""

  require_cmds curl awk sed grep sort

  index_url="${MIRROR_BASE}/${arch}/clients/ocp/"
  index="$(curl -fsSL --retry 3 --retry-delay 2 "${index_url}")" || fail "failed to fetch ${index_url}"

  versions="$(
    printf '%s\n' "${index}" |
      grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?/"' |
      sed -e 's|^href="||' -e 's|/"$||' || true
  )"
  [ -n "${versions}" ] || fail "could not parse any versions from ${index_url}; the mirror layout may have changed"

  if [ "${include_pre}" != "1" ]; then
    versions="$(printf '%s\n' "${versions}" | grep -v -- '-' || true)"
  fi

  read -r floor_major floor_minor <<<"$(arch_floor "${arch}")"
  versions="$(
    printf '%s\n' "${versions}" |
      awk -F'[.-]' -v maj="${floor_major}" -v min="${floor_minor}" \
        '$1 > maj || ($1 == maj && $2 >= min)' |
      sort_versions
  )"
  [ -n "${versions}" ] || fail "no versions found for ${arch}"

  # Newest minor first.
  minors="$(
    printf '%s\n' "${versions}" |
      awk -F'[.-]' '{ m = $1 "." $2; if (m != last) { a[++n] = m; last = m } }
                    END { for (i = n; i > 0; i--) print a[i] }'
  )"
  for minor in ${minors}; do
    newest="$(printf '%s\n' "${versions}" | awk -F'[.-]' -v m="${minor}" '$1 "." $2 == m' | tail -n 1)"
    if url_exists "$(version_dir_url "${arch}" "${newest}")/oc-mirror.tar.gz"; then
      ceiling="${minor}"
      break
    fi
  done
  [ -n "${ceiling}" ] || fail "no version on the mirror ships oc-mirror for ${arch}"

  printf '%s\n' "${versions}" |
    awk -F'[.-]' -v c="${ceiling}" 'BEGIN { split(c, cc, ".") }
      $1 < cc[1] || ($1 == cc[1] && $2 <= cc[2])'
}
