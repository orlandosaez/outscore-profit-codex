# Anchor Invoice Note Conventions

Lightweight invoice note conventions for tax recognition edge cases.

This is operating doctrine for V0.5.2. The classifier should enforce these conventions only where they are needed and should keep the default path simple for normal tax work.

## Default Behavior

Most tax filings need no Anchor invoice note.

By default, the classifier matches an FC `tax_filed` trigger by form type (`1040`, `1065`, `1120`, `990`) to the oldest pending revenue event under the same Anchor relationship. This handles roughly 95% of cases without changing team behavior.

The default rule is intentionally boring:

1. Read the filed-return form type from FC context.
2. Find pending tax revenue events under the same `anchor_relationship_id`.
3. Match by form type.
4. Recognize the oldest matching pending event.

## When A Note Is Required

Use a structured Anchor invoice note only for edge cases where "oldest pending event by form type" is not enough.

| Edge case | Required prefix | Example | Why it matters |
| --- | --- | --- | --- |
| Amended returns | `Amended TY:YYYY` | `Amended TY:2023` | Separates amended-year work from current-year original filings. |
| Late filings of older years when multiple years are pending simultaneously | `TY:YYYY` | `TY:2022` | Directs the classifier to the intended tax year instead of the oldest ambiguous event. |
| Fiscal year filers with non-calendar tax years | `FY:YYYY-MM` | `FY:2025-06` | Identifies the fiscal year-end month, such as a July-June fiscal year ending June 2025. |

## Classifier Patterns

The V0.5.2 classifier should match these structured tokens:

```regex
(TY|FY):\d{4}(-\d{2})?
```

It should also detect amended returns case-insensitively:

```regex
Amended
```

Examples that should parse:

- `TY:2022`
- `Amended TY:2023`
- `FY:2025-06`
- `FY:2025-06 final return`

Free-form text after the structured prefix is allowed but not parsed.

## Where The Note Goes

Put the structured note in the Anchor invoice note field.

Anchor sync should capture this into `profit_anchor_invoices.notes`. Confirm the exact column name during V0.5.2 implementation and create the column if it is absent.

Do not put these structured tokens in FC task titles unless the team already needs them there for workflow clarity. Anchor invoice notes are the canonical source for invoice-specific recognition hints.

## Operational Guidance

- Keep structured notes short, ideally under 30 characters.
- Put the structured prefix first.
- Free-form text after the prefix is fine but will not be parsed.
- Teams not working on tax invoices can ignore this convention entirely.
- Normal current-year original returns do not need notes.

## Tracked Tech Debt

See `docs/tech-debt.md`.

If invoice note conventions are inconsistently applied, the classifier falls back to default matching and may recognize against the wrong tax year. The V0.5.2 pipeline run log should flag any tax recognition where multiple pending events matched form type but only one was recognized, so ambiguity surfaces for manual review.
