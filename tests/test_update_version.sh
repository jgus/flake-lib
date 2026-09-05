#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils --command bash

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

write_empty_pin() {
  printf '%s\n' \
    '{' \
    '  version = "";' \
    '  sourceRev = "";' \
    '  sourceHash = "";' \
    '}' > "${TEST_ROOT}/pin.nix"
}

run_update() {
  local TRACK="${1}"
  FLAKE_ROOT="${TEST_ROOT}" \
    SOURCE_TYPE=github \
    GH_OWNER=openai \
    GH_REPO=codex \
    GH_TAG_PREFIX=rust-v \
    GH_TRACK="${TRACK}" \
    BUILD_ATTR=codex \
    HASH_MODE=prefetch \
    EXTRA_HASHES='[]' \
    PIN_HASHES='[]' \
    VERIFICATION=evaluate \
    SIBLINGS='[]' \
    bash "${UPDATE_VERSION}"
}

assert_pin() {
  grep -Fq 'version = "1.2.3";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceRev = "source-revision";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceHash = "sha256-source";' "${TEST_ROOT}/pin.nix"
}

write_empty_pin
run_update release
assert_pin

write_empty_pin
run_update tag
assert_pin
