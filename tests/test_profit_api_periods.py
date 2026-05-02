from __future__ import annotations

import unittest

from profit_api.periods import validate_period_month


class ProfitApiPeriodTests(unittest.TestCase):
    def test_validate_period_month_accepts_none_or_first_day_month(self) -> None:
        self.assertIsNone(validate_period_month(None))
        self.assertEqual(validate_period_month("2026-02-01"), "2026-02-01")

    def test_validate_period_month_rejects_malformed_values(self) -> None:
        invalid_values = [
            "2026-02-02",
            "2026-2-01",
            "02-01-2026",
            "2026-13-01",
            "latest",
        ]

        for value in invalid_values:
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    ValueError, "period must use YYYY-MM-01 format"
                ):
                    validate_period_month(value)

    def test_fastapi_route_maps_invalid_period_to_422(self) -> None:
        source = (  # source inspection keeps this test independent of FastAPI install.
            __import__("pathlib")
            .Path(__file__)
            .resolve()
            .parents[1]
            .joinpath("profit_api/app.py")
            .read_text(encoding="utf-8")
        )

        self.assertIn("HTTPException", source)
        self.assertIn("status_code=422", source)
        self.assertIn("validate_period_month(period)", source)


if __name__ == "__main__":
    unittest.main()
