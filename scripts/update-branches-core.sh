#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#curl nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#nix nixpkgs#coreutils --command bash

# Per-version branch orchestrator, shared across jgus sub-flakes via flake-lib.
# Runs on main, once per workflow run.
#
# For each upstream version >= $MINIMUM_TRACKING_VERSION, ensures:
#   - an exact branch `v<M>.<m>.<p>` exists and its pin is hash-validated
#   - aggregate pointer branches `v<M>.<m>`, `v<M>`, `main` are force-pushed to the
#     highest matching exact branch
#
# Single knob: $MINIMUM_TRACKING_VERSION. Permanent pins are done via git tags
# (which the action never touches); there is no in-band freeze list.
#
# Each existing exact branch is `git merge`d with origin/main before its update-version
# runs, so orchestrator/workflow improvements that land on main propagate forward through
# every branch's tree. Branch-owned files (pin.nix, flake.lock, flake.nix, ...) stay as-is
# via the `ours` merge driver declared in .gitattributes. The shared scripts themselves no
# longer live in the repo — they come from the flake-lib input, so the per-branch
# `nix flake update` below picks up their improvements automatically.
#
# Failures: per-branch update-version failures are surfaced as GH Actions ::warning::
# annotations + a step summary, and cause a non-zero exit at the end of the run.
#
# Per-flake variation is fully driven by env vars injected by flake-lib's mkUpdateBranches:
#   SOURCE_TYPE          pypi | github  (gitlab leaves are single-branch, no orchestrator)
#   PYPI_NAME            [pypi]
#   GH_OWNER/GH_REPO     [github]
#   PIN_SCHEMA           pypi | github | github-npm | github-yarn | version-only
#   BRANCH_OWNED_FILES   space-separated files update-version mutates per branch

set -euo pipefail
: "${MINIMUM_TRACKING_VERSION:?required env var}"

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

# --- Per-flake: list all upstream version strings, one per line ---
list_upstream_versions() {
  case "${SOURCE_TYPE}" in
    pypi)
      # sdist-only: wheel-only releases would 404 on fetchPypi.
      curl -sSfL "https://pypi.org/pypi/${PYPI_NAME}/json" \
        | jq -r '.releases | to_entries[] | select(.value | any(.packagetype == "sdist")) | .key'
      ;;
    github)
      gh api --paginate "/repos/${GH_OWNER}/${GH_REPO}/releases" --jq '.[].tag_name'
      ;;
    *)
      echo "error: update-branches does not support SOURCE_TYPE=${SOURCE_TYPE}" >&2
      exit 1
      ;;
  esac
}

# --- Per-flake: write a placeholder pin.nix with the requested version, empty hashes. ---
write_placeholder_pin() {
  local v="$1"
  case "${PIN_SCHEMA}" in
    pypi)
      cat > pin.nix <<EOF
{
  version = "${v}";
  hash = "";
}
EOF
      ;;
    github)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${v}";
  sourceRev = "";
  sourceHash = "";
}
EOF
      ;;
    github-npm)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${v}";
  sourceRev = "";
  sourceHash = "";
  npmDepsHash = "";
}
EOF
      ;;
    github-yarn)
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${v}";
  sourceRev = "";
  sourceHash = "";
  yarnHash = "";
}
EOF
      ;;
    version-only)
      # For flakes whose update-version rewrites the whole pin with a non-standard shape
      # (e.g. a keyed table of per-artifact hashes). The placeholder carries only the version;
      # update-version replaces the file entirely before any build.
      cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${v}";
}
EOF
      ;;
    *)
      echo "error: unknown PIN_SCHEMA=${PIN_SCHEMA}" >&2
      exit 1
      ;;
  esac
}

version_lt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Define the `ours` merge driver so .gitattributes' `merge=ours` rules take effect: `true` exits 0 without touching the file, leaving the branch's version.
git config merge.ours.driver true

echo "Querying upstream..."
mapfile -t raw_versions < <(list_upstream_versions)
if (( ${#raw_versions[@]} == 0 )); then
  echo "error: list_upstream_versions returned no rows (auth issue?)" >&2
  exit 1
fi
declare -a all_versions=()
for v in "${raw_versions[@]}"; do
  v="${v#[Vv]}"
  if [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+a-zA-Z0-9.]+)?$ ]]; then
    all_versions+=("${v}")
  fi
done

declare -a tracked=()
for v in "${all_versions[@]}"; do
  if ! version_lt "${v}" "${MINIMUM_TRACKING_VERSION}"; then
    tracked+=("${v}")
  fi
done
if (( ${#tracked[@]} == 0 )); then
  echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}; nothing to do."
  exit 0
fi
mapfile -t tracked < <(printf '%s\n' "${tracked[@]}" | sort -V)
echo "Tracking ${#tracked[@]} upstream versions: ${tracked[*]}"

git fetch --quiet origin
main_sha=$(git rev-parse --verify origin/main)

declare -a failed=()

for v in "${tracked[@]}"; do
  branch="v${v}"
  wt=$(mktemp -d)
  if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
    echo
    echo "=== Refreshing existing branch ${branch}"
    git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}" || true
    git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null
    # Merge orchestrator/workflow improvements from main; branch-owned files stay as-is per .gitattributes. No-op merges are silent.
    (cd "${wt}" && git merge --no-edit origin/main)
  else
    echo
    echo "=== Creating new branch ${branch} from main"
    git worktree add -B "${branch}" "${wt}" "${main_sha}" >/dev/null
    (cd "${wt}" && write_placeholder_pin "${v}")
  fi
  pushd "${wt}" >/dev/null
  set +e
  nix flake update --option post-build-hook ""
  FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}"
  uv_exit=$?
  set -e
  if (( uv_exit != 0 )); then
    failed+=("${v}")
    echo "::warning title=Branch ${branch} skipped::update-version failed for ${v} (exit ${uv_exit}). Likely an upstream defect at that release; see the orchestrator log above."
    echo "  WARN: update-version failed for ${branch} (exit ${uv_exit}); skipping." >&2
    popd >/dev/null
    git worktree remove --force "${wt}" >/dev/null
    continue
  fi
  # shellcheck disable=SC2086
  if ! git diff --quiet -- ${BRANCH_OWNED_FILES} || [[ -n "$(git ls-files --others --exclude-standard -- ${BRANCH_OWNED_FILES})" ]]; then
    # shellcheck disable=SC2086
    git add ${BRANCH_OWNED_FILES}
    git commit -q -m "auto: ${v} pin"
    git push --quiet origin "${branch}"
  else
    echo "  no change on ${branch}"
    # Merge may have advanced HEAD without touching tracked files we diff for; push if local HEAD is ahead of origin.
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${branch}")" ]]; then
      git push --quiet origin "${branch}"
    fi
  fi
  popd >/dev/null
  git worktree remove --force "${wt}" >/dev/null
done

git fetch --quiet origin
declare -A agg_target_version=()
record() { local key="$1" v="$2"; cur="${agg_target_version[$key]:-}"; if [[ -z "${cur}" ]] || version_lt "${cur}" "${v}"; then agg_target_version[$key]="${v}"; fi; }
for v in "${tracked[@]}"; do
  # Only consider exact branches that actually exist on origin (failed branches won't have a ref to advance aggregates to).
  if ! git ls-remote --exit-code --heads origin "v${v}" >/dev/null 2>&1; then
    continue
  fi
  IFS='.' read -r M m _ <<<"${v}"
  record "main" "${v}"
  record "v${M}" "${v}"
  record "v${M}.${m}" "${v}"
done

echo
echo "=== Updating aggregate pointers"
for agg in "${!agg_target_version[@]}"; do
  target_v="${agg_target_version[$agg]}"
  target_branch="v${target_v}"
  target_sha=$(git rev-parse --verify "origin/${target_branch}")
  cur_sha=$(git rev-parse --verify "origin/${agg}" 2>/dev/null || echo "")
  if [[ "${cur_sha}" == "${target_sha}" ]]; then
    echo "  ${agg} already at ${target_branch}"
    continue
  fi
  echo "  ${agg} -> ${target_branch} (${target_sha:0:8})"
  git push --force --quiet origin "${target_sha}:refs/heads/${agg}"
done

echo
if (( ${#failed[@]} > 0 )); then
  echo "=== ${#failed[@]} branch(es) failed: ${failed[*]}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## :warning: ${#failed[@]} branch(es) failed to update"
      echo
      echo "These upstream versions couldn't be packaged. They were skipped; aggregate pointers reflect only the successful branches."
      echo
      for v in "${failed[@]}"; do
        echo "- \`v${v}\`"
      done
      echo
      echo "See the orchestrator log for the underlying error per version."
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

echo "Done."
