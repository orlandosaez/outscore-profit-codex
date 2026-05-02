from __future__ import annotations

import re


PERIOD_MONTH_PATTERN = re.compile(r"^\d{4}-(0[1-9]|1[0-2])-01$")


def validate_period_month(period: str | None) -> str | None:
    if period is None:
        return None
    if not PERIOD_MONTH_PATTERN.match(period):
        raise ValueError("period must use YYYY-MM-01 format")
    return period
