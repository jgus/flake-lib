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
  local TRACK="${1}" TAG_PREFIXES="${2}" RELEASE_TAG="${3}" TAGS="${4}"
  local REQUESTED="${5:-}" REQUESTED_REF="${6:-}"
  local -a ARGS=()
  if [[ -n "${REQUESTED}" ]]; then
    ARGS+=("${REQUESTED}")
  fi
  if [[ -n "${REQUESTED_REF}" ]]; then
    ARGS+=("${REQUESTED_REF}")
  fi
  FLAKE_ROOT="${TEST_ROOT}" \
    SOURCE_TYPE=github \
    GH_OWNER=openai \
    GH_REPO=codex \
    GH_TAG_PREFIXES="${TAG_PREFIXES}" \
    GH_TRACK="${TRACK}" \
    TEST_RELEASE_TAG="${RELEASE_TAG}" \
    TEST_TAGS="${TAGS}" \
    BUILD_ATTR=codex \
    HASH_MODE=prefetch \
    EXTRA_HASHES='[]' \
    PIN_HASHES='[]' \
    VERIFICATION=evaluate \
    SIBLINGS='[]' \
    bash "${UPDATE_VERSION}" "${ARGS[@]}"
}

assert_pin() {
  grep -Fq 'version = "1.2.3";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceRev = "source-revision";' "${TEST_ROOT}/pin.nix"
  grep -Fq 'sourceHash = "sha256-source";' "${TEST_ROOT}/pin.nix"
}

write_empty_pin
run_update release '["rust-v"]' rust-v1.2.3 ''
assert_pin

write_empty_pin
run_update tag '["rust-v"]' '' $'v9.9.9\nrust-v1.2.3'
assert_pin

write_empty_pin
run_update release '["v","V",""]' v1.2.3 ''
assert_pin

write_empty_pin
run_update release '["rust-v"]' '' '' rust-v1.2.3
assert_pin

write_empty_pin
run_update release '["rust-v"]' '' '' 1.2.3 1.2.3
assert_pin
