import { useEffect, useMemo, useState } from "react";

import { EmptyRow } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const reserveEndpoint = `${apiBase}/profit/admin/subscription-reserve`;
const reserveSummaryEndpoint = `${apiBase}/profit/admin/subscription-reserve/summary`;

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function formatMoney(value) {
  if (value === null || value === undefined) return "—";
  return money.format(Number(value));
}

function formatPct(value) {
  if (value === null || value === undefined) return "—";
  return `${Number(value).toFixed(1)}%`;
}

function formatDate(value) {
  if (!value) return "—";
  return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function stateBadge(state) {
  return (
    <span className={`pipeline-status-badge pipeline-status-${state ?? "unknown"}`}>
      {state ?? "unknown"}
    </span>
  );
}

const STATE_ORDER = {
  overbudget: 0,
  breakeven: 1,
  profitable: 2,
  no_labor_recorded: 3,
  no_fee: 4,
};

const STATE_LABEL = {
  overbudget: "Overbudget",
  breakeven: "Breakeven",
  profitable: "Profitable",
  no_labor_recorded: "No labor recorded (90d)",
  no_fee: "No subscription fee",
};

const FILTER_OPTIONS = [
  { label: "All", value: "" },
  { label: "Overbudget", value: "overbudget" },
  { label: "Breakeven", value: "breakeven" },
  { label: "Profitable", value: "profitable" },
  { label: "No labor recorded", value: "no_labor_recorded" },
];

export default function SubscriptionReserve() {
  const [rows, setRows] = useState([]);
  const [summary, setSummary] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [stateFilter, setStateFilter] = useState("");

  async function load() {
    setLoading(true);
    setError("");
    try {
      const stateParam = stateFilter ? `?state=${stateFilter}` : "";
      const [sumRes, rowsRes] = await Promise.all([
        fetch(reserveSummaryEndpoint),
        fetch(`${reserveEndpoint}${stateParam}${stateParam ? "&" : "?"}limit=500`),
      ]);
      if (!sumRes.ok) throw new Error(`summary ${sumRes.status}`);
      if (!rowsRes.ok) throw new Error(`rows ${rowsRes.status}`);
      const sumPayload = await sumRes.json();
      const rowsPayload = await rowsRes.json();
      setSummary(sumPayload);
      const sorted = (rowsPayload.rows ?? []).slice().sort((a, b) => {
        const stateDiff =
          (STATE_ORDER[a.profitability_state] ?? 9) -
          (STATE_ORDER[b.profitability_state] ?? 9);
        if (stateDiff !== 0) return stateDiff;
        const pctA = a.monthly_contribution_margin_pct;
        const pctB = b.monthly_contribution_margin_pct;
        if (pctA === null || pctA === undefined) return 1;
        if (pctB === null || pctB === undefined) return -1;
        return Number(pctA) - Number(pctB);
      });
      setRows(sorted);
    } catch (err) {
      setError(err instanceof Error ? err.message : "load failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stateFilter]);

  return (
    <main className="pipeline-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Subscription Service Reserve</h1>
          <span>
            Per-client labor cost (90-day trailing avg) vs. monthly subscription fee.
            Surfaces overbudget Subscription/Mixed clients and informs Mixed
            engagement reclassification decisions (T&C revenue recognition).
          </span>
        </div>
        <button className="btn btn-primary" onClick={load} type="button" disabled={loading}>
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </header>

      {summary ? (
        <section className="panel" aria-label="Subscription reserve summary">
          <div className="panel-title">
            <h2>Aggregate</h2>
            <span className="pipeline-meta-count">
              {summary.client_count ?? 0} client{summary.client_count === 1 ? "" : "s"}
            </span>
          </div>
          <dl className="pipeline-run-meta">
            <dt>Total monthly fee</dt>
            <dd>{formatMoney(summary.total_monthly_subscription_fee)}</dd>
            <dt>Total monthly labor (avg)</dt>
            <dd>{formatMoney(summary.total_monthly_avg_labor_cost)}</dd>
            <dt>Total monthly margin</dt>
            <dd>{formatMoney(summary.total_monthly_contribution_margin)}</dd>
            <dt>Aggregate margin %</dt>
            <dd>{formatPct(summary.aggregate_margin_pct)}</dd>
            <dt>Overbudget</dt>
            <dd>{summary.by_state?.overbudget ?? 0}</dd>
            <dt>Breakeven</dt>
            <dd>{summary.by_state?.breakeven ?? 0}</dd>
            <dt>Profitable</dt>
            <dd>{summary.by_state?.profitable ?? 0}</dd>
            <dt>No labor (90d)</dt>
            <dd>{summary.by_state?.no_labor_recorded ?? 0}</dd>
          </dl>
        </section>
      ) : null}

      {error ? <div className="error-toast">{error}</div> : null}

      <section className="panel">
        <div className="panel-title">
          <h2>Clients</h2>
          <label style={{ marginLeft: "auto" }}>
            <span style={{ marginRight: "6px" }}>Filter:</span>
            <select value={stateFilter} onChange={(e) => setStateFilter(e.target.value)}>
              {FILTER_OPTIONS.map((opt) => (
                <option key={opt.value} value={opt.value}>{opt.label}</option>
              ))}
            </select>
          </label>
        </div>
        <div className="table-wrap">
          <table className="pipeline-table">
            <thead>
              <tr>
                <th>Client</th>
                <th>Engagement</th>
                <th>Monthly fee</th>
                <th>Monthly labor (avg)</th>
                <th>Margin</th>
                <th>Margin %</th>
                <th>State</th>
                <th>90d hours</th>
                <th>Staff</th>
                <th>Last entry</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.anchor_relationship_id}>
                  <td>{r.client_name}</td>
                  <td>{r.engagement_type ?? "—"}</td>
                  <td>{formatMoney(r.monthly_subscription_fee)}</td>
                  <td>{formatMoney(r.monthly_avg_labor_cost)}</td>
                  <td>{formatMoney(r.monthly_contribution_margin)}</td>
                  <td>{formatPct(r.monthly_contribution_margin_pct)}</td>
                  <td>{stateBadge(STATE_LABEL[r.profitability_state] ?? r.profitability_state)}</td>
                  <td>{Number(r.last_90d_hours ?? 0).toFixed(1)}</td>
                  <td>{r.distinct_staff ?? "—"}</td>
                  <td>{formatDate(r.last_entry_date)}</td>
                </tr>
              ))}
              {rows.length === 0 && !loading ? (
                <EmptyRow
                  colSpan={10}
                  hint="No Subscription / Mixed clients match the current filter."
                  label="Empty"
                />
              ) : null}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
