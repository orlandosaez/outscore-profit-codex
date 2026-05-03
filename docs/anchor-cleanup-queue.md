# Anchor Cleanup Queue

- Resolved 2026-05-02: Collectiv Inc. / December 2025 bookkeeping. Initial hypothesis was that duplicate Anchor invoice `SBC-00029` needed to be voided, but live Anchor data showed the actual void was on `SBC-00015`; `SBC-00029` was the legitimate paid invoice. The `SBC-00015` revenue event was manually excluded with `recognition_status = 'excluded_voided_invoice'`, and `fc_task_id` 76008241 was approved as a one-off so recognition landed only against `SBC-00029`.
