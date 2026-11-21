#!/usr/bin/env bash
# tests/smoke.sh — end-to-end test of the plugin under mise and asdf.
#
# Starts a throwaway Fedora container with podman, mounts this repo read-only
# at /work and runs tests/container.sh inside it. On a macOS host it first
# checks that bin/download refuses to run.
#
# Env:
#   TOOLS            tools to test, default "mise asdf"
#   TEST_VERSION     version installed with the default tarball (4.20.0)
#   RHEL9_VERSION    version installed with the rhel9 variant (4.19.0)
#   ASDF_VERSION     asdf release to test against (v0.20.2)
#   CONTAINER_IMAGE  dnf-based image (docker.io/library/fedora:42)

set -euo pipefail

CONTAINER_IMAGE="${CONTAINER_IMAGE:-docker.io/library/fedora:42}"
CONTAINER_NAME="oc-mirror-plugin-smoke-$$"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v podman >/dev/null 2>&1 || {
  echo "ERROR: 'podman' is required but not installed" >&2
  exit 1
}

if [ "$(uname -s)" = "Darwin" ]; then
  echo "=== macOS host: bin/download must refuse to run"
  if out="$(ASDF_INSTALL_VERSION=4.20.0 ASDF_DOWNLOAD_PATH="$(mktemp -d)" "${REPO_ROOT}/bin/download" 2>&1)"; then
    echo "  FAIL bin/download succeeded on macOS" >&2
    exit 1
  fi
  case "${out}" in
    *"not supported on macOS"*) echo "  ok   ${out}" ;;
    *)
      echo "  FAIL unexpected error: ${out}" >&2
      exit 1
      ;;
  esac
fi

cleanup() { podman rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "=== starting ${CONTAINER_IMAGE}"
podman run -d --name "${CONTAINER_NAME}" -v "${REPO_ROOT}:/work:ro" \
  "${CONTAINER_IMAGE}" sleep infinity >/dev/null

# gpgme provides libgpgme.so.11, which oc-mirror links against.
if ! dnf_log="$(podman exec "${CONTAINER_NAME}" dnf -y -q install curl tar gzip gawk ca-certificates gpgme 2>&1)"; then
  printf '%s\n' "${dnf_log}" >&2
  echo "ERROR: failed to install test dependencies in the container" >&2
  exit 1
fi

podman exec \
  -e TOOLS="${TOOLS:-mise asdf}" \
  -e TEST_VERSION="${TEST_VERSION:-4.20.0}" \
  -e RHEL9_VERSION="${RHEL9_VERSION:-4.19.0}" \
  -e ASDF_VERSION="${ASDF_VERSION:-v0.20.2}" \
  "${CONTAINER_NAME}" bash /work/tests/container.sh

echo ""
echo "==> SMOKE TEST PASSED"
