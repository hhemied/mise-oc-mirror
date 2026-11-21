#!/usr/bin/env bash
# tests/container.sh — runs INSIDE the test container (started by smoke.sh).
#
# Exercises the plugin at /work three ways: the scripts directly, through
# mise, and through asdf. Everything talks to the real Red Hat mirror.
#
# Env: TOOLS ("mise asdf"), TEST_VERSION, RHEL9_VERSION, ASDF_VERSION.

set -euo pipefail

PLUGIN=/work
TOOLS="${TOOLS:-mise asdf}"
TEST_VERSION="${TEST_VERSION:-4.20.0}"
RHEL9_VERSION="${RHEL9_VERSION:-4.19.0}"
ASDF_VERSION="${ASDF_VERSION:-v0.20.2}"

export PATH="${HOME}/.local/bin:${PATH}"

section() { printf '\n=== %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }
die() {
  printf '  FAIL %s\n' "$*" >&2
  exit 1
}
# contains <haystack> <needle> <label>
contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) die "$3 — expected to find '$2' in: ${1:0:400}" ;;
  esac
}
# reports <version>: what `oc-mirror version --short` prints for a release.
# Red Hat stamps every build of a minor as <minor>.0 (4.22.23 reports
# "4.22.0-..."), so only the minor identifies the build.
reports() { printf 'Client Version: %s.' "${1%.*}"; }
# expect_fail <label> <expected stderr text> <cmd...>
expect_fail() {
  local label="$1" text="$2" out
  shift 2
  if out="$("$@" 2>&1)"; then
    die "${label} — command succeeded but should have failed"
  fi
  contains "${out}" "${text}" "${label}"
}

# ---------------------------------------------------------------------------
section "plugin scripts, called directly"
# ---------------------------------------------------------------------------
all="$("${PLUGIN}/bin/list-all")"
[ "$(printf '%s\n' "${all}" | wc -l)" -eq 1 ] || die "list-all must print exactly one line"
pass "list-all prints one space-separated line"
contains " ${all} " " ${TEST_VERSION} " "list-all contains ${TEST_VERSION}"
case "${all}" in *-rc.* | *-ec.*) die "list-all must not contain pre-releases by default" ;; esac
pass "list-all has no pre-releases by default"
case " ${all}" in *" 4.9."*) die "list-all must not contain 4.9.x (no oc-mirror tarball)" ;; esac
pass "list-all leaves out versions below the floor"

newest="${all##* }"
latest="$("${PLUGIN}/bin/latest-stable")"
[ "${latest}" = "${newest}" ] || die "latest-stable (${latest}) != last list-all entry (${newest})"
pass "latest-stable equals the last list-all entry (${latest})"
arch="$(uname -m)"
[ "${arch}" = "arm64" ] && arch="aarch64"
[ "${arch}" = "amd64" ] && arch="x86_64"
curl -fsIL -o /dev/null "https://mirror.openshift.com/pub/openshift-v4/${arch}/clients/ocp/${latest}/oc-mirror.tar.gz" ||
  die "latest version ${latest} has no oc-mirror.tar.gz"
pass "latest version has a tarball on the mirror"

minor="${TEST_VERSION%.*}"
q="$("${PLUGIN}/bin/latest-stable" "${minor}")"
contains "${q}" "${minor}." "latest-stable ${minor} -> ${q}"

pre="$(OC_MIRROR_INCLUDE_PRERELEASE=1 "${PLUGIN}/bin/list-all")"
contains "${pre}" "-rc." "OC_MIRROR_INCLUDE_PRERELEASE=1 adds pre-releases"
contains "${pre}" "4.20.0-rc.3 4.20.0 " "pre-releases sort before their final release"

x86="$(OC_MIRROR_ARCH=x86_64 "${PLUGIN}/bin/list-all")"
contains " ${x86}" " 4.10.0 " "OC_MIRROR_ARCH=x86_64 lists from 4.10"

expect_fail "invalid arch is rejected" "unsupported architecture" \
  env OC_MIRROR_ARCH=sparc "${PLUGIN}/bin/list-all"
expect_fail "invalid variant is rejected" "unsupported variant" \
  env OC_MIRROR_VARIANT=rhel7 ASDF_INSTALL_VERSION="${TEST_VERSION}" ASDF_DOWNLOAD_PATH=/tmp/dl-variant "${PLUGIN}/bin/download"
expect_fail "missing version fails clearly" "failed to download" \
  env ASDF_INSTALL_VERSION=4.20.9999 ASDF_DOWNLOAD_PATH=/tmp/dl-missing "${PLUGIN}/bin/download"
[ -z "$(ls -A /tmp/dl-missing 2>/dev/null)" ] || die "failed download left files behind"
pass "failed download leaves no files behind"
expect_fail "git refs are rejected" "only released versions" \
  env ASDF_INSTALL_TYPE=ref ASDF_INSTALL_VERSION=main ASDF_DOWNLOAD_PATH=/tmp/dl-ref "${PLUGIN}/bin/download"

# ---------------------------------------------------------------------------
test_mise() {
  section "mise"
  curl -fsSL https://mise.run | sh >/dev/null 2>&1
  mise --version

  mkdir -p /tmp/mise-default && cd /tmp/mise-default
  cat >mise.toml <<EOF
[plugins]
oc-mirror = "${PLUGIN}"

[tools]
oc-mirror = "${TEST_VERSION}"
EOF
  local out
  out="$(mise install 2>&1)" || die "mise install failed: ${out}"
  contains "${out}" "checksum OK" "mise install ${TEST_VERSION} verified the checksum"
  contains "${out}" "/oc-mirror.tar.gz" "mise install used the default tarball"
  out="$(mise exec -- oc-mirror version --short 2>&1)" || die "oc-mirror version failed: ${out}"
  contains "${out}" "$(reports "${TEST_VERSION}")" "mise exec -- oc-mirror version reports the ${TEST_VERSION%.*} build"
  out="$(mise ls-remote oc-mirror)"
  contains "${out}" "${TEST_VERSION}" "mise ls-remote lists ${TEST_VERSION}"
  out="$(mise latest oc-mirror)"
  [ "${out}" = "${latest}" ] || die "mise latest (${out}) != ${latest}"
  pass "mise latest oc-mirror -> ${out}"

  mkdir -p /tmp/mise-rhel9 && cd /tmp/mise-rhel9
  cat >mise.toml <<EOF
[plugins]
oc-mirror = "${PLUGIN}"

[tools]
oc-mirror = { version = "${RHEL9_VERSION}", variant = "rhel9" }
EOF
  out="$(mise install 2>&1)" || die "mise install (rhel9) failed: ${out}"
  contains "${out}" "/oc-mirror.rhel9.tar.gz" "mise variant = \"rhel9\" used the rhel9 tarball"
  out="$(mise exec -- oc-mirror version --short 2>&1)" || die "rhel9 oc-mirror version failed: ${out}"
  contains "${out}" "$(reports "${RHEL9_VERSION}")" "rhel9 build runs and reports the ${RHEL9_VERSION%.*} build"
}

# ---------------------------------------------------------------------------
test_asdf() {
  section "asdf"
  local goarch out
  case "$(uname -m)" in
    x86_64) goarch=amd64 ;;
    *) goarch=arm64 ;;
  esac
  curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${goarch}.tar.gz" |
    tar -xz -C /usr/local/bin asdf
  asdf --version

  # Copy the working tree instead of `asdf plugin add`, which clones from git
  # and would test the last commit rather than the files on disk.
  mkdir -p "${HOME}/.asdf/plugins"
  rm -rf "${HOME}/.asdf/plugins/oc-mirror"
  cp -R "${PLUGIN}" "${HOME}/.asdf/plugins/oc-mirror"

  out="$(asdf list all oc-mirror "${minor}")"
  contains "${out}" "${TEST_VERSION}" "asdf list all oc-mirror ${minor} lists ${TEST_VERSION}"
  if printf '%s\n' "${out}" | grep -qv "^${minor//./\\.}"; then
    die "asdf list all ${minor} returned other versions (list-all is not space-separated?)"
  fi
  pass "asdf list all filter works (output is space-separated)"
  out="$(asdf latest oc-mirror)"
  [ "${out}" = "${latest}" ] || die "asdf latest (${out}) != ${latest}"
  pass "asdf latest oc-mirror -> ${out}"
  out="$(asdf latest oc-mirror "${minor}")"
  contains "${out}" "${minor}." "asdf latest oc-mirror ${minor} -> ${out}"

  out="$(asdf install oc-mirror "${TEST_VERSION}" 2>&1)" || die "asdf install failed: ${out}"
  contains "${out}" "checksum OK" "asdf install ${TEST_VERSION} verified the checksum"
  mkdir -p /tmp/asdf-default && cd /tmp/asdf-default
  asdf set oc-mirror "${TEST_VERSION}"
  out="$(asdf exec oc-mirror version --short 2>&1)" || die "asdf exec oc-mirror failed: ${out}"
  contains "${out}" "$(reports "${TEST_VERSION}")" "asdf exec oc-mirror version reports the ${TEST_VERSION%.*} build"
  [ -x "${HOME}/.asdf/shims/oc-mirror" ] || die "asdf did not create a shim"
  pass "asdf created the oc-mirror shim"

  out="$(OC_MIRROR_VARIANT=rhel9 asdf install oc-mirror "${RHEL9_VERSION}" 2>&1)" || die "asdf install (rhel9) failed: ${out}"
  contains "${out}" "/oc-mirror.rhel9.tar.gz" "OC_MIRROR_VARIANT=rhel9 used the rhel9 tarball"
}

for tool in ${TOOLS}; do
  "test_${tool}"
done

printf '\nALL CHECKS PASSED (%s)\n' "${TOOLS}"
