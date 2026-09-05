#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#git --command bash

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

write_pin() {
  local FILE="${1}" VERSION="${2}" HASH="${3}"
  printf '%s\n' \
    '{' \
    "  version = \"${VERSION}\";" \
    "  assets.fixture = \"${HASH}\";" \
    '}' > "${FILE}"
}

initialize_repository() {
  CASE_ROOT=$(mktemp -d "${TEST_ROOT}/case.XXXXXX")
  REMOTE="${CASE_ROOT}/remote.git"
  CHECKOUT="${CASE_ROOT}/checkout"

  git init -q --bare "${REMOTE}"
  git init -q -b main "${CHECKOUT}"
  git -C "${CHECKOUT}" remote add origin "${REMOTE}"
  write_pin "${CHECKOUT}/pin.nix" "1.0.0" "original-hash"
  printf '%s\n' 'pin.nix merge=ours' > "${CHECKOUT}/.gitattributes"
  git -C "${CHECKOUT}" add pin.nix .gitattributes
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm initial
  git -C "${CHECKOUT}" push -q -u origin main
}

seed_exact_branch() {
  local VERSION="${1}"
  git -C "${CHECKOUT}" switch -q -C "v${VERSION}" main
  write_pin "${CHECKOUT}/pin.nix" "${VERSION}" "original-hash"
  git -C "${CHECKOUT}" add pin.nix
  git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm "${VERSION}"
  git -C "${CHECKOUT}" push -q origin "v${VERSION}"
  git -C "${CHECKOUT}" switch -q main
}

point_aggregate() {
  local AGGREGATE="${1}" VERSION="${2}"
  git --git-dir="${REMOTE}" update-ref "refs/heads/${AGGREGATE}" "refs/heads/v${VERSION}"
}

run_update() {
  local VERSIONS="${1}" TAG_PREFIXES="${2:-[\"v\",\"V\",\"\"]}"
  (
    cd "${CHECKOUT}"
    BRANCH_OWNED_FILES=pin.nix \
    GH_OWNER=example \
    GH_REPO=example \
    GH_TAG_PREFIXES="${TAG_PREFIXES}" \
    MINIMUM_TRACKING_VERSION=1.0.0 \
    MIN_VERSION_COMPONENTS=3 \
    PIN_SCHEMA=version-only \
    SOURCE_TYPE=github \
    TEST_VERSIONS="${VERSIONS}" \
    VERSION_CANON='' \
    VERSION_OVERRIDES='{}' \
    bash "${UPDATE_BRANCHES_CORE}"
  )
}

assert_ref_version() {
  local REF="${1}" VERSION="${2}"
  git --git-dir="${REMOTE}" show "refs/heads/${REF}:pin.nix" | grep -Fq "version = \"${VERSION}\";"
}

assert_same_ref() {
  local LEFT="${1}" RIGHT="${2}"
  [[ "$(git --git-dir="${REMOTE}" rev-parse "refs/heads/${LEFT}")" == "$(git --git-dir="${REMOTE}" rev-parse "refs/heads/${RIGHT}")" ]]
}

initialize_repository
run_update '1.2.3-rc1'
assert_same_ref v1.2 v1.2.3-rc1
assert_same_ref v1 v1.2.3-rc1
assert_ref_version main 1.0.0
assert_ref_version v1.2.3-rc1 1.2.3-rc1
git --git-dir="${REMOTE}" show 'refs/heads/v1.2.3-rc1:pin.nix' | grep -Fq 'assets.fixture = "updated-hash";'

initialize_repository
seed_exact_branch 1.2.3-rc1
point_aggregate v1.2 1.2.3-rc1
point_aggregate v1 1.2.3-rc1
point_aggregate main 1.2.3-rc1
run_update $'1.2.3-rc1\n1.2.4-rc1'
assert_same_ref v1.2 v1.2.4-rc1
assert_same_ref v1 v1.2.4-rc1
assert_same_ref main v1.2.4-rc1

initialize_repository
seed_exact_branch 1.2.1-rc1
seed_exact_branch 1.2.2
point_aggregate v1.2 1.2.1-rc1
point_aggregate v1 1.2.2
point_aggregate main 1.2.2
run_update $'1.2.1-rc1\n1.2.2\n1.2.3-rc1'
assert_same_ref v1.2 v1.2.3-rc1
assert_same_ref v1 v1.2.2
assert_same_ref main v1.2.2

initialize_repository
seed_exact_branch 1.2.3-rc1
point_aggregate v1.2 1.2.3-rc1
point_aggregate v1 1.2.3-rc1
point_aggregate main 1.2.3-rc1
run_update $'1.2.3-rc1\n1.2.3'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3

initialize_repository
run_update $'V1.2.2\nv1.2.3'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3

initialize_repository
run_update $'v9.9.9\nrust-v1.2.3' '["rust-v"]'
assert_same_ref v1.2 v1.2.3
assert_same_ref v1 v1.2.3
assert_same_ref main v1.2.3
