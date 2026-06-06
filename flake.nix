{
  description = "Shared library for jgus sub-flakes: per-version-branch orchestrator, update-version machinery, and PyPI package builders.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      lib = import ./lib;
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (self) lib;
        # Example spec used to smoke-test the generators (no network: building the
        # writeShellApplications only runs shellcheck on the exec wrappers).
        exampleSource = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };
        update-version = lib.mkUpdateVersion { inherit pkgs; source = exampleSource; buildAttr = "iso639-lang"; };
        update-branches = lib.mkUpdateBranches { inherit pkgs; source = exampleSource; pinSchema = "pypi"; };
        # Exercises the new seams: github source, build-failure hash, an extra hash field.
        update-version-github = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          buildAttr = "example";
          hashMode = "build-failure";
          extraHashes = [ "npmDepsHash" ];
        };
        revalidate-hash = lib.mkRevalidateHash { inherit pkgs; buildAttr = "example"; };
        # github commit-tracking (default-branch HEAD -> 0-unstable-DATE), as searxng-mcp uses.
        update-version-github-commit = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; track = "commit"; };
          buildAttr = "example";
        };
        # JS-deps hooks: each writeShellApplication is shellcheck-validated at build. mkComposedHook wraps a shared hook beside a bespoke one.
        npm-shipped-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; fetcherVersion = 2; };
        npm-generated-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; source = "generated"; };
        yarn-hook = lib.mkJsDepsHook { inherit pkgs; manager = "yarn"; };
        composed-hook = lib.mkComposedHook { inherit pkgs; hooks = [ npm-generated-hook yarn-hook ]; };
        # getExe returns an exe path string; wrap so it's a derivation the checks can build.
        hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";
      in
      {
        packages = { inherit update-version update-branches update-version-github update-version-github-commit revalidate-hash; };
        checks = {
          inherit update-version update-branches update-version-github update-version-github-commit revalidate-hash;
          npm-shipped-hook = hookCheck "npm-shipped-hook" npm-shipped-hook;
          npm-generated-hook = hookCheck "npm-generated-hook" npm-generated-hook;
          yarn-hook = hookCheck "yarn-hook" yarn-hook;
          composed-hook = hookCheck "composed-hook" composed-hook;
        };
      });
}
