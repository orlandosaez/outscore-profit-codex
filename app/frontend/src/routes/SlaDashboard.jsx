import { useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, Clock3, Hourglass, PauseCircle, RefreshCw } from "lucide-react";
import { Link } from "react-router-dom";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";
import { Stat } from "./Dashboard.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const summaryEndpoint = `${apiBase}/profit/admin/sla/summary`;
const clientsEndpoint = `${apiBase}/profit/admin/sla/clients`;
const workloadEndpoint = `${apiBase}/profit/admin/sla/workload`;
const performanceEndpoint = `${apiBase}/profit/admin/sla/performance`;

const PANELS = {
  clients: { label: "Per-client SLA status", endpoint: clientsEndpoint },
  workload: { label: "Per-staff workload", endpoint: workloadEndpoint },
  performance: { label: "90-day staff/service performance", endpoint: performanceEndpoint },
};
const EMPTY_PANEL = { rows: [], loading: false, error: "" };
const STATE_LABELS = {
  at_risk: "At-Risk",
  breached: "Breached",
  not_applicable: "Not Applicable",
  on_track: "On Track",
  waiting_on_client: "Waiting-on-Client",
};

function numberValue(value) {
  if (value === null || value === undefined || value === "") return "-";
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric.toLocaleString() : value;
}

function countValue(summary, keys) {
  for (const key of keys) {
    if (summary[key] !== null && summary[key] !== undefined) return numberValue(summary[key]);
  }
  return "0";
}

function textValue(...values) {
  const value = values.find((item) => item !== null && item !== undefined && item !== "");
  return value === undefined ? "-" : value;
}

function formatDate(value) {
  if (!value || value === "-") return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "-";
  return date.toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function percentValue(value) {
  if (value === null || value === undefined || value === "") return "-";
  const numeric = Number(value);
  return Number.isFinite(numeric) ? `${(numeric * 100).toFixed(1)}%` : "-";
}

function stateBadge(state) {
  const normalized = String(state ?? "unknown");
  const className = `sla-state-badge sla-state-${normalized.replaceAll("_", "-")}`;
  return <span className={className}>{STATE_LABELS[normalized] ?? normalized.replaceAll("_", " ")}</span>;
}

function PanelFrame({ children, error, id, loading, title }) {
  return (
    <section className="panel sla-panel" id={id}>
      <div className="panel-title sla-panel-title">
        <h2>{title}</h2>
      </div>
      {error ? <div className="error-toast sla-panel-error">{error}</div> : null}
      {loading ? (
        <EmptyState label={`Loading ${title}`} hint="Fetching the latest SLA snapshot." />
      ) : children}
    </section>
  );
}

export default function SlaDashboard() {
  const [summary, setSummary] = useState({});
  const [summaryLoading, setSummaryLoading] = useState(false);
  const [summaryError, setSummaryError] = useState("");
  const [panels, setPanels] = useState({
    clients: EMPTY_PANEL,
    workload: EMPTY_PANEL,
    performance: EMPTY_PANEL,
  });

  async function loadSummary() {
    setSummaryLoading(true);
    setSummaryError("");
    try {
      const response = await fetch(summaryEndpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `SLA summary request failed: ${response.status}`);
      setSummary(payload.summary ?? payload);
    } catch (err) {
      setSummaryError(err instanceof Error ? err.message : "SLA summary request failed");
      setSummary({});
    } finally {
      setSummaryLoading(false);
    }
  }

  async function loadPanel(panelKey, config) {
    setPanels((current) => ({
      ...current,
      [panelKey]: { ...(current[panelKey] ?? EMPTY_PANEL), loading: true, error: "" },
    }));
    try {
      const response = await fetch(config.endpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `SLA ${config.label} request failed: ${response.status}`);
      setPanels((current) => ({
        ...current,
        [panelKey]: { rows: payload.rows ?? [], loading: false, error: "" },
      }));
    } catch (err) {
      setPanels((current) => ({
        ...current,
        [panelKey]: {
          rows: [],
          loading: false,
          error: err instanceof Error ? err.message : `SLA ${config.label} request failed`,
        },
      }));
    }
  }

  function refreshPage() {
    loadSummary();
    Object.entries(PANELS).forEach(([panelKey, config]) => loadPanel(panelKey, config));
  }

  useEffect(() => {
    refreshPage();
  }, []);

  return (
    <main className="pipeline-page sla-dashboard-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>SLA Dashboard</h1>
          <span>Read-only SLA status, workload, queue, and 90-day performance views.</span>
        </div>
        <div className="manual-hero-actions">
          <Link className="btn btn-secondary" to="/admin/weekly-review">Weekly Review</Link>
          <Link className="btn btn-secondary" to="/admin/sla/backfill">Anchor backfill</Link>
          <button className="icon-button" onClick={refreshPage} disabled={summaryLoading} title="Refresh SLA data" type="button">
            <RefreshCw size={18} aria-hidden="true" />
          </button>
        </div>
      </header>

      {summaryError ? <div className="error-toast">{summaryError}</div> : null}
      <div className="stats-grid sla-summary-grid">
        <Stat
          detail={summaryLoading ? "Loading" : "Total applicable"}
          icon={Clock3}
          label="Total Applicable"
          value={countValue(summary, ["total_applicable", "total_clients", "open_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Past target"}
          icon={AlertTriangle}
          label="Breached"
          tone="bad"
          value={countValue(summary.states ?? summary, ["breached", "breached_count", "breach_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Near target"}
          icon={Hourglass}
          label="At-Risk"
          tone="warn"
          value={countValue(summary.states ?? summary, ["at_risk", "at_risk_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Client-dependent"}
          icon={PauseCircle}
          label="Waiting-on-Client"
          value={countValue(summary.states ?? summary, ["waiting_on_client", "waiting_on_client_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Outside SLA"}
          icon={CheckCircle2}
          label="Not Applicable"
          tone="good"
          value={countValue(summary.states ?? summary, ["not_applicable", "not_applicable_count"])}
        />
      </div>

      <PanelFrame
        error={panels.clients.error}
        id="sla-client-status"
        loading={panels.clients.loading}
        title={PANELS.clients.label}
      >
        <div className="table-wrap sla-table-wrap">
          <table className="sla-table sla-client-table">
            <thead>
              <tr>
                <th>Target SLA Day</th>
                <th>State</th>
                <th>Age Days</th>
                <th>Staff</th>
                <th>Service</th>
                <th>Workflow Status</th>
                <th>Client/Group</th>
                <th>Last Activity</th>
              </tr>
            </thead>
            <tbody>
              {panels.clients.rows.length ? (
                panels.clients.rows.map((row, index) => (
                  <tr key={row.anchor_relationship_id ?? row.fc_client_id ?? index}>
                    <td>{numberValue(textValue(row.target_sla_day, row.default_sla_day))}</td>
                    <td>{stateBadge(row.sla_state)}</td>
                    <td>{numberValue(row.age_days)}</td>
                    <td>{textValue(row.assigned_staff_name, row.staff_name, row.staff_source)}</td>
                    <td>{textValue(row.service_name, row.macro_service_type, `${numberValue(row.service_count)} services`)}</td>
                    <td>{textValue(row.latest_workflow_status, row.workflow_status)}</td>
                    <td>
                      <span className="sla-primary">{textValue(row.fc_client_name, row.anchor_client_business_name)}</span>
                      <span className="sla-muted">{textValue(row.group_name, row.anchor_relationship_id)}</span>
                    </td>
                    <td>{formatDate(textValue(row.last_activity_at, row.latest_revenue_event_loaded_at, row.next_target_date))}</td>
                  </tr>
                ))
              ) : (
                <EmptyRow colSpan={8} label="No client SLA rows" hint="No applicable client SLA data is available for this view." />
              )}
            </tbody>
          </table>
        </div>
      </PanelFrame>

      <PanelFrame
        error={panels.workload.error}
        id="sla-staff-workload"
        loading={panels.workload.loading}
        title={PANELS.workload.label}
      >
        <div className="table-wrap sla-table-wrap">
          <table className="sla-table sla-workload-table">
            <thead>
              <tr>
                <th>Staff</th>
                <th>Open</th>
                <th>Breached</th>
                <th>At-Risk</th>
                <th>Waiting-on-Client</th>
                <th>Total/In-Flight</th>
              </tr>
            </thead>
            <tbody>
              {panels.workload.rows.length ? (
                panels.workload.rows.map((row, index) => (
                  <tr key={row.assigned_staff_name ?? row.staff_name ?? index}>
                    <td>
                      <span className="sla-primary">{textValue(row.assigned_staff_name, row.staff_name, "Unassigned")}</span>
                      <span className="sla-muted">{textValue(row.staff_source)}</span>
                    </td>
                    <td>{numberValue(row.open_count)}</td>
                    <td>{numberValue(row.breached_count)}</td>
                    <td>{numberValue(row.at_risk_count)}</td>
                    <td>{numberValue(row.waiting_on_client_count)}</td>
                    <td>{numberValue(textValue(row.total_in_flight_count, row.in_flight_count))}</td>
                  </tr>
                ))
              ) : (
                <EmptyRow colSpan={6} label="No staff workload rows" hint="No staff workload data is available yet." />
              )}
            </tbody>
          </table>
        </div>
      </PanelFrame>

      <PanelFrame
        error={panels.performance.error}
        id="sla-performance"
        loading={panels.performance.loading}
        title={PANELS.performance.label}
      >
        <p className="sla-panel-note">Fixed 90-day performance by staff and service.</p>
        <div className="table-wrap sla-table-wrap">
          <table className="sla-table sla-performance-table">
            <thead>
              <tr>
                <th>Staff</th>
                <th>Service</th>
                <th>90-day Completed</th>
                <th>90-day Breached</th>
                <th>At-Risk/Partial</th>
                <th>Breach Rate</th>
                <th>Avg Age Days</th>
                <th>Last Activity</th>
              </tr>
            </thead>
            <tbody>
              {panels.performance.rows.length ? (
                panels.performance.rows.map((row, index) => (
                  <tr key={`${row.staff_name ?? "staff"}-${row.service_name ?? "service"}-${index}`}>
                    <td>{textValue(row.staff_name, "Unassigned")}</td>
                    <td>{textValue(row.service_name)}</td>
                    <td>{numberValue(row.total_completed)}</td>
                    <td>{numberValue(row.total_breached)}</td>
                    <td>{numberValue(row.total_partial_or_at_risk)}</td>
                    <td>{percentValue(row.breach_rate)}</td>
                    <td>{numberValue(row.avg_age_days_to_complete)}</td>
                    <td>{formatDate(row.last_completed_at)}</td>
                  </tr>
                ))
              ) : (
                <EmptyRow colSpan={8} label="No 90-day performance rows" hint="Completed task performance will appear when the fixed 90-day window has data." />
              )}
            </tbody>
          </table>
        </div>
      </PanelFrame>
    </main>
  );
}
