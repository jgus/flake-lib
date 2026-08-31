#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#git --command bash

set -euo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

REMOTE="${TEST_ROOT}/remote.git"
CHECKOUT="${TEST_ROOT}/checkout"

git init -q --bare "${REMOTE}"
git init -q -b main "${CHECKOUT}"
git -C "${CHECKOUT}" remote add origin "${REMOTE}"
printf '%s\n' \
  '{' \
  '  version = "1.0.0";' \
  '  assets.fixture = "original-hash";' \
  '}' > "${CHECKOUT}/pin.nix"
git -C "${CHECKOUT}" add pin.nix
git -C "${CHECKOUT}" -c user.name=test -c user.email=test@example.com commit -qm initial
git -C "${CHECKOUT}" push -q -u origin main

(
  cd "${CHECKOUT}"
  BRANCH_OWNED_FILES=pin.nix \
  GH_OWNER=example \
  GH_REPO=example \
  MINIMUM_TRACKING_VERSION=1.0.1 \
  MIN_VERSION_COMPONENTS=3 \
  PIN_SCHEMA=version-only \
  SOURCE_TYPE=github \
  VERSION_CANON='' \
  VERSION_OVERRIDES='{}' \
  bash "${UPDATE_BRANCHES_CORE}"
)

git --git-dir="${REMOTE}" show 'refs/heads/v1.0.1:pin.nix' | grep -Fq 'version = "1.0.1";'
git --git-dir="${REMOTE}" show 'refs/heads/v1.0.1:pin.nix' | grep -Fq 'assets.fixture = "updated-hash";'
