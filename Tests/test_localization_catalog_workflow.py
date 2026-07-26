import runpy
import unittest
from pathlib import Path


VALIDATE = runpy.run_path(
    Path(__file__).resolve().parents[1] / "script/localization_catalog_workflow.py"
)["validate_catalog_values"]


def localized(value: str) -> dict[str, object]:
    return {"stringUnit": {"state": "translated", "value": value}}


class LocalizationCatalogWorkflowTests(unittest.TestCase):
    def test_required_locales_fail_closed(self) -> None:
        payload = {
            "strings": {
                "label.english_only": {"localizations": {"en": localized("English")}},
                "label.chinese_only": {"localizations": {"zh-Hans": localized("中文")}},
            }
        }
        problems: list[str] = []

        VALIDATE(payload, problems)

        self.assertIn("label.english_only: missing zh-Hans stringUnit", problems)
        self.assertIn("label.chinese_only: missing en stringUnit", problems)


if __name__ == "__main__":
    unittest.main()
