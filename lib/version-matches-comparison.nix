actual:
{ operator, version, ... }:
let
  comparison = builtins.compareVersions actual version;
  matches = {
    "===" = actual == version;
    "==" = comparison == 0;
    "!=" = comparison != 0;
    "<=" = comparison != 1;
    ">=" = comparison != -1;
    "<" = comparison == -1;
    ">" = comparison == 1;
  };
in
matches.${operator} or (throw "versionMatchesComparison: unsupported operator ${operator}")
