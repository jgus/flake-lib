{ versionMatchesComparison }:
{
  testExactMatch = {
    expr = versionMatchesComparison "1.0" { operator = "==="; version = "1.0"; };
    expected = true;
  };
  testExactMismatch = {
    expr = versionMatchesComparison "1.0" { operator = "==="; version = "1.00"; };
    expected = false;
  };
  testEquivalentMatch = {
    expr = versionMatchesComparison "1.0" { operator = "=="; version = "1.00"; };
    expected = true;
  };
  testDifferent = {
    expr = versionMatchesComparison "1.0" { operator = "!="; version = "2.0"; };
    expected = true;
  };
  testLessThan = {
    expr = versionMatchesComparison "1.0" { operator = "<"; version = "2.0"; };
    expected = true;
  };
  testLessThanOrEqual = {
    expr = versionMatchesComparison "1.0" { operator = "<="; version = "1.0"; };
    expected = true;
  };
  testGreaterThan = {
    expr = versionMatchesComparison "2.0" { operator = ">"; version = "1.0"; };
    expected = true;
  };
  testGreaterThanOrEqual = {
    expr = versionMatchesComparison "1.0" { operator = ">="; version = "1.0"; };
    expected = true;
  };
  testUnsupportedOperator = {
    expr = (builtins.tryEval (versionMatchesComparison "1.0" { operator = "~="; version = "1.0"; })).success;
    expected = false;
  };
}
