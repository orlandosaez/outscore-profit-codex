import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const backfillEndpoint = `${apiBase}/profit/admin/sla/backfill`;

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function textValue(...values) {
  const value = values.find((item) => item !== null && item !== undefined && item !== "");
  return value === undefined ? "-" : value;
}

function numberValue(value) {
  if (value === null || value === undefined || value === "") return "-";
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric.toLocaleString() : value;
}

function formatDate(value) {
  if (!value || value === "-") return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function formatMoney(value) {
  if (value === null || value === undefined || value === "") return "-";
  const numeric = Number(value);
  return Number.isFinite(numeric) ? money.format(numeric) : "-";
}

function yesNoBadge(value) {
  return (
    <span className={`sla-boolean-badge ${value ? "sla-boolean-yes" : "sla-boolean-no"}`}>
      {value ? "Yes" : "No"}
    </span>
  );
}

function missingAnchorState(row) {
  if (row.missing_anchor_signal) return "Missing agreement or invoice state";
  return textValue(row.anchor_display_status, row.match_status, "Anchor state present");
}

export default function SlaBackfill() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function loadBackfill() {
    setLoading(true);
    setError("");
    try {
      const response = await fetch(backfillEndpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `SLA backfill request failed: ${response.status}`);
      setRows(payload.rows ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : "SLA backfill request failed");
      setRows([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadBackfill();
  }, []);

  return (
    <main className="pipeline-page sla-backfill-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Anchor Backfill</h1>
          <span>Read-only queue for QBO-settled clients that need Anchor convergence.</span>
        </div>
        <Link className="btn btn-secondary" to="/admin/sla">Back to SLA</Link>
      </header>

      {error ? <div className="error-toast">{error}</div> : null}
      <section className="panel sla-panel" id="sla-anchor-backfill">
        <div className="panel-title sla-panel-title">
          <h2>Backfill queue</h2>
        </div>
        {loading ? (
          <EmptyState label="Loading Anchor backfill queue" hint="Fetching the latest read-only queue snapshot." />
        ) : (
          <div className="table-wrap sla-table-wrap">
            <table className="sla-table sla-backfill-table">
              <thead>
                <tr>
                  <th>Client/Group</th>
                  <th>QBO Payment Evidence</th>
                  <th>Missing Anchor State</th>
                  <th>Age Days</th>
                  <th>auto_transition_eligible</th>
                </tr>
              </thead>
              <tbody>
                {rows.length ? (
                  rows.map((row, index) => (
                    <tr key={row.classification_id ?? row.fc_client_id ?? index}>
                      <td>
                        <span className="sla-primary">{textValue(row.fc_client_name, row.anchor_client_business_name)}</span>
                        <span className="sla-muted">{textValue(row.group_name, row.group_id)}</span>
                      </td>
                      <td>
                        <span className="sla-primary">{textValue(row.qbo_payment_id, "No QBO payment id")}</span>
                        <span className="sla-muted">{formatDate(row.collected_at)} / {formatMoney(row.collected_amount)}</span>
                      </td>
                      <td>{missingAnchorState(row)}</td>
                      <td>{numberValue(row.days_since_oldest_qbo_payment)}</td>
                      <td>{yesNoBadge(Boolean(row.auto_transition_eligible))}</td>
                    </tr>
                  ))
                ) : (
                  <EmptyRow colSpan={5} label="No Anchor backfill rows" hint="No QBO-settled clients currently need Anchor backfill." />
                )}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </main>
  );
}
