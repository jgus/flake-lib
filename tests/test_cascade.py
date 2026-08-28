import importlib.util
import os
import unittest
from pathlib import Path

from packaging.markers import default_environment
from packaging.specifiers import SpecifierSet

MODULE_SPEC = importlib.util.spec_from_file_location(
    "cascade", Path(os.environ["CASCADE_PY"])
)
assert MODULE_SPEC is not None
assert MODULE_SPEC.loader is not None
CASCADE = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(CASCADE)


class CascadeTests(unittest.TestCase):
    def test_exact_pin_uses_exact_branch(self) -> None:
        self.assertEqual(
            CASCADE.resolve_ref("exact", "", SpecifierSet("==3.4.4")), "v3.4.4"
        )

    def test_bounded_range_uses_latest_compatible_aggregate(self) -> None:
        self.assertEqual(
            CASCADE.resolve_ref(
                "resolve",
                "sibling-package",
                SpecifierSet(">=1.2,<2"),
                ["1.2.0", "1.8.4", "2.0.0"],
            ),
            "v1.8",
        )

    def test_unbounded_minimum_uses_main(self) -> None:
        self.assertEqual(
            CASCADE.resolve_ref("resolve", "", SpecifierSet(">=2026.8.16")), "main"
        )

    def test_metadata_normalizes_names_and_evaluates_markers(self) -> None:
        metadata = {
            "info": {
                "requires_dist": [
                    "Sibling_Package==2.4.1; python_version >= '3.12'",
                    "sibling-package==1.9.0; python_version < '3.12'",
                ]
            }
        }
        environment = default_environment()
        environment["python_version"] = "3.14"
        specifiers = CASCADE.requirement_specifiers(
            metadata, "sibling-package", environment
        )
        self.assertEqual(specifiers, SpecifierSet("==2.4.1"))
        self.assertEqual(
            CASCADE.resolve_metadata_ref(
                metadata, "sibling-package", "", "exact", environment
            ),
            "v2.4.1",
        )

    def test_final_release_sorts_after_prerelease(self) -> None:
        versions = ["3.4.4", "3.4.3", "3.4.4a1"]
        self.assertEqual(
            CASCADE.sorted_versions(versions, "0.0.0"), ["3.4.3", "3.4.4a1", "3.4.4"]
        )
        self.assertEqual(
            CASCADE.sorted_versions(versions, "0.0.0", stable_only=True),
            ["3.4.3", "3.4.4"],
        )


if __name__ == "__main__":
    unittest.main()
