import { useEffect, useMemo, useState } from "react";

import { EmptyRow } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const alertsEndpoint = `${apiBase}/profit/admin/data-quality-alerts`;
const summaryEndpoint = `${apiBase}/profit/admin/data-quality-alerts/summary`;

// Operator-facing labels for the 11 alert categories (A–K).
const CATEGORY_LABELS = {
  fc_stale_record: "Stale FC client (possible ghost)",
  anchor_no_fc_match: "Active Anchor agreement — no FC match",
  engagement_type_unclassified: "Engagement type unclassified",
  subscription_with_manual_service: "Subscription with manual service (T&C conflict)",
  subscription_billing_gap: "Subscription billing gap",
  orphan_attribution_duplicate: "Orphan attribution duplicate",
  parent_child_1040_false_positive: "Parent–child 1040 false positive",
  paid_anchor_invoice_not_cleared: "Paid Anchor invoice not cleared",
  manual_invoice_already_invoiced: "Manual invoice already invoiced",
  catalog_gap_service_no_rule: "Service catalog gap (no recognition rule)",
  label_unresolved_with_sibling_candidate: "Unresolved label with sibling candidate",
};

const SEVERITY_ORDER = { high: 0, medium: 1, low: 2 };

function severityBadge(severity) {
  return (
    <span className={`pipeline-status-badge pipeline-status-${severity ?? "unknown"}`}>
      {severity ?? "unknown"}
    </span>
  );
}

function statusChip(auditStatus) {
  const label =
    auditStatus === "critical"
      ? "Critical"
      : auditStatus === "alerts"
      ? "Alerts"
      : "Clean";
  return (
    <span className={`pipeline-status-badge pipeline-status-${auditStatus ?? "unknown"}`}>
      {label}
    </span>
  );
}

function categoryLabel(code) {
  return CATEGORY_LABELS[code] ?? code;
}

function formatDateTime(value) {
  if (!value) return "—";
  return new Date(value).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function groupRows(rows) {
  const grouped = new Map();
  for (const row of rows) {
    const key = row.alert_category ?? "unknown";
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(row);
  }
  // Sort categories: severity of first row, then by name. High-severity first.
  return [...grouped.entries()]
    .map(([category, rowsForCat]) => ({
      category,
      severity: rowsForCat[0]?.severity ?? "medium",
      rows: rowsForCat,
    }))
    .sort((a, b) => {
      const sevDiff = (SEVERITY_ORDER[a.severity] ?? 9) - (SEVERITY_ORDER[b.severity] ?? 9);
      if (sevDiff !== 0) return sevDiff;
      return a.category.localeCompare(b.category);
    });
}

export default function DataQuality() {
  const [rows, setRows] = useState([]);
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function load() {
    setLoading(true);
    setError("");
    try {
      const [summaryRes, alertsRes] = await Promise.all([
        fetch(summaryEndpoint),
        fetch(`${alertsEndpoint}?limit=1000`),
      ]);
      if (!summaryRes.ok) throw new Error(`Summary request failed: ${summaryRes.status}`);
      if (!alertsRes.ok) throw new Error(`Alerts request failed: ${alertsRes.status}`);
      const summaryPayload = await summaryRes.json();
      const alertsPayload = await alertsRes.json();
      setSummary(summaryPayload);
      setRows(alertsPayload.rows ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Data quality request failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
  }, []);

  const grouped = useMemo(() => groupRows(rows), [rows]);

  return (
    <main className="pipeline-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Data Quality (Self-Audit)</h1>
          <span>
            Cross-source consistency checks across Anchor + FC + QBO — surfaces issues
            before they spawn false positives in the weekly review queue.
          </span>
        </div>
        <button className="btn btn-primary" onClick={load} type="button" disabled={loading}>
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      {summary ? (
        <section className="panel" aria-label="Self-audit summary">
          <div className="panel-title">
            <h2>Summary</h2>
            {statusChip(summary.audit_status)}
          </div>
          <dl className="pipeline-run-meta">
            <dt>Total findings</dt>
            <dd>{summary.total ?? 0}</dd>
            <dt>High severity</dt>
            <dd>{summary.by_severity?.high ?? 0}</dd>
            <dt>Medium severity</dt>
            <dd>{summary.by_severity?.medium ?? 0}</dd>
            <dt>Low severity</dt>
            <dd>{summary.by_severity?.low ?? 0}</dd>
          </dl>
        </section>
      ) : null}

      {error ? <div className="error-toast">{error}</div> : null}

      {grouped.length ? (
        grouped.map(({ category, severity, rows: catRows }) => (
          <section key={category} className="panel">
            <details open={severity === "high"}>
              <summary className="panel-title">
                <h2>{categoryLabel(category)}</h2>
                {severityBadge(severity)}
                <span className="pipeline-meta-count">
                  {catRows.length} finding{catRows.length === 1 ? "" : "s"}
                </span>
              </summary>
              <div className="table-wrap">
                <table className="pipeline-table">
                  <thead>
                    <tr>
                      <th>Subject</th>
                      <th>Description</th>
                      <th>Detected</th>
                      <th>Action</th>
                    </tr>
                  </thead>
                  <tbody>
                    {catRows.map((row) => (
                      <tr key={`${category}:${row.subject_id ?? row.subject_name}`}>
                        <td>{row.subject_name ?? row.subject_id ?? "—"}</td>
                        <td>{row.description ?? "—"}</td>
                        <td>{formatDateTime(row.detected_at)}</td>
                        <td>
                          {row.action_url ? (
                            <a
                              href={row.action_url}
                              target="_blank"
                              rel="noreferrer noopener"
                            >
                              Open
                            </a>
                          ) : (
                            "—"
                          )}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </details>
          </section>
        ))
      ) : !loading ? (
        <section className="panel">
          <div className="panel-title">
            <h2>All clear</h2>
          </div>
          <p className="empty-state-hint">
            No data-quality findings. Re-run after the next pipeline cycle.
          </p>
        </section>
      ) : null}
    </main>
  );
}
