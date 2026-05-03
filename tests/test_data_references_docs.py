from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DataReferencesDocsTests(unittest.TestCase):
    def test_data_references_readme_documents_canonical_artifacts(self) -> None:
        readme = (ROOT / "docs/data-references/README.md").read_text(encoding="utf-8")

        self.assertIn("canonical home for reference artifacts", readme)
        self.assertIn("anchor services.csv", readme)
        self.assertIn("Anchor service catalog with FC tag mapping", readme)
        self.assertIn("client-staff-assignments.xlsx", readme)
        self.assertIn("Per-client staff ownership matrix", readme)
        self.assertIn("qbo-product-services.csv", readme)
        self.assertIn("QBO product/service hierarchy export", readme)
        self.assertIn("sbc-profit-and-loss.csv", readme)
        self.assertIn("Reference P&L for company-level GP validation", readme)
        self.assertIn("kebab-case filenames", readme)
        self.assertIn("anchor services.csv is the historical exception", readme)
        self.assertIn("V0.6+ will replace Anchor and QBO files with live API syncs", readme)
        self.assertIn("Updating the seed when reference data changes", readme)
        self.assertIn("python3 scripts/generate_service_crosswalk_seed.py", readme)
        self.assertIn("commit the regenerated migration", readme)
        self.assertIn("re-apply", readme)

    def test_service_recognition_rules_document_fc_tag_column(self) -> None:
        doc = (ROOT / "docs/service-recognition-rules.md").read_text(encoding="utf-8")

        self.assertIn("FC tag", doc)
        self.assertIn("S BOOKA", doc)
        self.assertIn("S 1040A", doc)
        self.assertIn("S BILL", doc)
        self.assertIn("Shared umbrella tags", doc)

    def test_recognition_triggers_contract_documents_service_crosswalk(self) -> None:
        doc = (ROOT / "docs/data-contracts/recognition-triggers.md").read_text(encoding="utf-8")

        self.assertIn("V0.5.2.1 Service Crosswalk", doc)
        self.assertIn("fc_tag", doc)
        self.assertIn("qbo_category_path", doc)
        self.assertIn("qbo_product_name", doc)
        self.assertIn("Shared umbrella tags", doc)
        self.assertIn("profit_anchor_services_without_tag", doc)


if __name__ == "__main__":
    unittest.main()
