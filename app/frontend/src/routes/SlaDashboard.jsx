import { useEffect, useMemo, useState } from "react";
import { AlertTriangle, CheckCircle2, Clock3, Hourglass, PauseCircle } from "lucide-react";
import { Link } from "react-router-dom";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";
import { Stat } from "./Dashboard.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const summaryEndpoint = `${apiBase}/profit/admin/sla/summary`;
const clientsEndpoint = `${apiBase}/profit/admin/sla/clients`;
const workloadEndpoint = `${apiBase}/profit/admin/sla/workload`;
const queueEndpoint = `${apiBase}/profit/admin/sla/queue`;
const performanceEndpoint = `${apiBase}/profit/admin/sla/performance`;

const TABS = [
  { id: "clients", label: "Clients", endpoint: clientsEndpoint },
  { id: "workload", label: "Workload", endpoint: workloadEndpoint },
  { id: "queue", label: "Queue", endpoint: queueEndpoint },
  { id: "performance", label: "Performance", endpoint: performanceEndpoint },
];

const EMPTY_PANEL = { rows: [], loading: false, error: "" };

function countValue(summary, keys) {
  for (const key of keys) {
    if (summary[key] !== null && summary[key] !== undefined) return Number(summary[key]).toLocaleString();
  }
  return "0";
}

function panelTitle(tabId) {
  if (tabId === "clients") return "Per-client SLA status";
  if (tabId === "workload") return "Per-staff workload";
  if (tabId === "queue") return "Breach and at-risk queue";
  return "90-day rolling performance";
}

export default function SlaDashboard() {
  const [summary, setSummary] = useState({});
  const [summaryLoading, setSummaryLoading] = useState(false);
  const [summaryError, setSummaryError] = useState("");
  const [activeTab, setActiveTab] = useState("clients");
  const [panels, setPanels] = useState({
    clients: EMPTY_PANEL,
    workload: EMPTY_PANEL,
    queue: EMPTY_PANEL,
    performance: EMPTY_PANEL,
  });

  const activeTabConfig = useMemo(
    () => TABS.find((tab) => tab.id === activeTab) ?? TABS[0],
    [activeTab],
  );
  const activePanel = panels[activeTab] ?? EMPTY_PANEL;

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

  async function loadPanel(tab) {
    setPanels((current) => ({
      ...current,
      [tab.id]: { ...(current[tab.id] ?? EMPTY_PANEL), loading: true, error: "" },
    }));
    try {
      const response = await fetch(tab.endpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `SLA ${tab.label} request failed: ${response.status}`);
      setPanels((current) => ({
        ...current,
        [tab.id]: { rows: payload.rows ?? [], loading: false, error: "" },
      }));
    } catch (err) {
      setPanels((current) => ({
        ...current,
        [tab.id]: {
          rows: [],
          loading: false,
          error: err instanceof Error ? err.message : `SLA ${tab.label} request failed`,
        },
      }));
    }
  }

  useEffect(() => {
    loadSummary();
  }, []);

  useEffect(() => {
    loadPanel(activeTabConfig);
  }, [activeTabConfig]);

  return (
    <main className="pipeline-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>SLA Dashboard</h1>
          <span>Read-only SLA status, workload, queue, and 90-day performance views.</span>
        </div>
        <Link className="btn btn-secondary" to="/admin/sla/backfill">Anchor backfill</Link>
      </header>

      {summaryError ? <div className="error-toast">{summaryError}</div> : null}
      <div className="stat-grid">
        <Stat
          detail={summaryLoading ? "Loading" : "Current SLA work"}
          icon={Clock3}
          label="Open"
          value={countValue(summary, ["open_count", "total_open", "total_applicable"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Past target"}
          icon={AlertTriangle}
          label="Breached"
          tone="bad"
          value={countValue(summary, ["breached_count", "breach_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Near target"}
          icon={Hourglass}
          label="At Risk"
          tone="warn"
          value={countValue(summary, ["at_risk_count", "atRisk_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Client-dependent"}
          icon={PauseCircle}
          label="Waiting"
          value={countValue(summary, ["waiting_on_client_count", "waiting_count"])}
        />
        <Stat
          detail={summaryLoading ? "Loading" : "Outside SLA"}
          icon={CheckCircle2}
          label="Not Applicable"
          tone="good"
          value={countValue(summary, ["not_applicable_count", "not_applicable"])}
        />
      </div>

      <section className="panel">
        <div className="panel-title">
          <h2>{panelTitle(activeTab)}</h2>
          <div className="button-row" role="tablist" aria-label="SLA read views">
            {TABS.map((tab) => (
              <button
                aria-selected={activeTab === tab.id}
                className={activeTab === tab.id ? "btn btn-primary" : "btn btn-secondary"}
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                role="tab"
                type="button"
              >
                {tab.label}
              </button>
            ))}
          </div>
        </div>
        {activePanel.error ? <div className="error-toast">{activePanel.error}</div> : null}
        {activePanel.loading ? (
          <EmptyState label={`Loading ${activeTabConfig.label.toLowerCase()} view`} hint="Fetching the latest SLA snapshot." />
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>View</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {activePanel.rows.length ? (
                  activePanel.rows.slice(0, 5).map((row, index) => (
                    <tr key={row.id ?? row.fc_client_id ?? row.staff_name ?? index}>
                      <td>{row.client_name ?? row.staff_name ?? activeTabConfig.label}</td>
                      <td>Task 6 panel detail</td>
                    </tr>
                  ))
                ) : (
                  <EmptyRow colSpan={2} label={`No ${activeTabConfig.label.toLowerCase()} rows`} hint="There is no SLA data for this view yet." />
                )}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </main>
  );
}
