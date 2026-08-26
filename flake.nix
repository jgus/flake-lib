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
        # Building the generators fetches nothing — writeShellApplication only shellchecks the exec wrappers.
        exampleSource = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };
        update-version = lib.mkUpdateVersion { inherit pkgs; source = exampleSource; buildAttr = "iso639-lang"; };
        update-branches = lib.mkUpdateBranches { inherit pkgs; source = exampleSource; pinSchema = "pypi"; };
        update-version-github = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          buildAttr = "example";
          hashMode = "build-failure";
          extraHashes = [ "npmDepsHash" ];
        };
        update-version-github-pnpm = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          buildAttr = "example";
          buildFailureHash = "pnpmDepsHash";
        };
        update-branches-github-pnpm = lib.mkUpdateBranches {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; };
          pinSchema = "github-pnpm";
        };
        revalidate-hash = lib.mkRevalidateHash { inherit pkgs; buildAttr = "example"; };
        # track="commit": default-branch HEAD becomes version 0-unstable-DATE.
        update-version-github-commit = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "github"; owner = "example"; repo = "example"; track = "commit"; };
          buildAttr = "example";
        };
        update-version-huggingface = lib.mkUpdateVersion {
          inherit pkgs;
          source = { type = "huggingface"; repo = "example/model"; files = [ "config.json" ]; };
          buildAttr = "model";
        };
        npm-shipped-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; fetcherVersion = 2; };
        npm-generated-hook = lib.mkJsDepsHook { inherit pkgs; manager = "npm"; source = "generated"; };
        yarn-hook = lib.mkJsDepsHook { inherit pkgs; manager = "yarn"; };
        composed-hook = lib.mkComposedHook { inherit pkgs; hooks = [ npm-generated-hook yarn-hook ]; };
        hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";
      in
      {
        packages = { inherit update-version update-branches update-version-github update-version-github-pnpm update-version-github-commit update-version-huggingface update-branches-github-pnpm revalidate-hash; };
        checks = {
          inherit update-version update-branches update-version-github update-version-github-pnpm update-version-github-commit update-version-huggingface update-branches-github-pnpm revalidate-hash;
          npm-shipped-hook = hookCheck "npm-shipped-hook" npm-shipped-hook;
          npm-generated-hook = hookCheck "npm-generated-hook" npm-generated-hook;
          yarn-hook = hookCheck "yarn-hook" yarn-hook;
          composed-hook = hookCheck "composed-hook" composed-hook;
        };
      });
}
