# Generates a flake-lib artifactHook that computes a JS package-manager offline-deps hash for the pinned rev and prints it as one `name=value` line (the seam mkUpdateVersion captures into pin.nix). Returns an executable path, usable directly as `artifactHook` or composed via mkComposedHook.
#
#   manager        : "npm" | "yarn"
#   source         : "shipped"   — upstream ships the lockfile; fetch it from the repo at NEW_REV (buildNpmPackage/fetchYarnDeps consume upstream's directly)
#                    "generated" — upstream ships none; regenerate it from package.json and vendor it into FLAKE_ROOT (the flake's build copies ./package-lock.json). npm only.
#   field          : pin field name (default npmDepsHash / yarnHash)
#   fetcherVersion : npm only; when set, export NPM_FETCHER_VERSION (must match the flake's npmDepsFetcherVersion — it changes the hash)
{ pkgs
, manager
, source ? "shipped"
, field ? null
, fetcherVersion ? null
}:
let
  inherit (pkgs) lib;
  fieldName =
    if field != null then field
    else if manager == "npm" then "npmDepsHash"
    else "yarnHash";
  prefetch = if manager == "npm" then pkgs.prefetch-npm-deps else pkgs.prefetch-yarn-deps;
  npmFetcherEnv = lib.optionalString (manager == "npm" && fetcherVersion != null)
    "export NPM_FETCHER_VERSION=${toString fetcherVersion}";

  # raw media type, not the JSON `.content` field: the latter is base64 and capped at 1 MB by the Contents API (large lockfiles come back empty). raw streams up to 100 MB.
  ghFetch = file: ''gh api "/repos/''${GH_OWNER}/''${GH_REPO}/contents/${file}?ref=''${NEW_REV}" -H "Accept: application/vnd.github.raw"'';

  body =
    if manager == "npm" && source == "shipped" then ''
      ${ghFetch "package-lock.json"} > "''${work}/package-lock.json"
      hash=$(prefetch-npm-deps "''${work}/package-lock.json")
    ''
    else if manager == "npm" && source == "generated" then ''
      ${ghFetch "package.json"} > "''${work}/package.json"
      ( cd "''${work}" && HOME="''${work}" npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 )
      cp "''${work}/package-lock.json" "''${FLAKE_ROOT}/package-lock.json"
      hash=$(prefetch-npm-deps "''${FLAKE_ROOT}/package-lock.json")
    ''
    else if manager == "yarn" && source == "shipped" then ''
      ${ghFetch "yarn.lock"} > "''${work}/yarn.lock"
      # prefetch-yarn-deps prints the hash then a trailing blank line; take the last non-empty line, normalize to SRI.
      hash=$(prefetch-yarn-deps "''${work}/yarn.lock" 2>/dev/null | awk 'NF{last=$0} END{print last}')
      if [[ "''${hash}" != sha256-* ]]; then
        hash=$(nix hash convert --hash-algo sha256 --to sri "''${hash}")
      fi
    ''
    else throw "mkJsDepsHook: unsupported (manager=${manager}, source=${source})";
in
lib.getExe (pkgs.writeShellApplication {
  name = "js-deps-hook-${manager}-${source}";
  runtimeInputs = [ pkgs.gh pkgs.coreutils prefetch pkgs.nix ]
    ++ lib.optionals (manager == "npm" && source == "generated") [ pkgs.nodejs ]
    ++ lib.optionals (manager == "yarn") [ pkgs.gawk ];
  text = ''
    work="$(mktemp -d)"
    trap 'rm -rf "''${work}"' EXIT
    ${npmFetcherEnv}
    ${body}
    echo "${fieldName}=''${hash}"
  '';
})
