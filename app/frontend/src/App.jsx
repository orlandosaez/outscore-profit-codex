import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  CircleDollarSign,
  ClipboardCheck,
  Gauge,
  RefreshCw,
  TableProperties,
  UserRoundCheck,
  UsersRound,
} from "lucide-react";

const endpoint = "/api/profit/admin/dashboard";

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

const pct = new Intl.NumberFormat("en-US", {
  style: "percent",
  maximumFractionDigits: 1,
});

function formatMoney(value) {
  return money.format(Number(value ?? 0));
}

function formatPct(value) {
  return value == null ? "n/a" : pct.format(Number(value));
}

function monthLabel(value) {
  if (!value) return "n/a";
  return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    year: "numeric",
  });
}

function Stat({ icon: Icon, label, value, detail, tone = "neutral" }) {
  return (
    <section className={`stat stat-${tone}`}>
      <div className="stat-icon">
        <Icon size={18} aria-hidden="true" />
      </div>
      <div>
        <p>{label}</p>
        <strong>{value}</strong>
        <span>{detail}</span>
      </div>
    </section>
  );
}

function EmptyRow({ colSpan, label }) {
  return (
    <tr>
      <td colSpan={colSpan} className="empty">
        {label}
      </td>
    </tr>
  );
}

function App() {
  const [snapshot, setSnapshot] = useState(null);
  const [status, setStatus] = useState("loading");
  const [error, setError] = useState("");

  async function loadDashboard() {
    setStatus("loading");
    setError("");
    try {
      const response = await fetch(endpoint);
      if (!response.ok) {
        throw new Error(`Dashboard request failed: ${response.status}`);
      }
      setSnapshot(await response.json());
      setStatus("ready");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Dashboard request failed");
      setStatus("error");
    }
  }

  useEffect(() => {
    loadDashboard();
  }, []);

  const company = snapshot?.company ?? {};
  const latestStaffRows = useMemo(() => {
    const period = company.latest_period_month;
    return (snapshot?.staff_gp ?? []).filter((row) => row.period_month === period);
  }, [company.latest_period_month, snapshot]);

  return (
    <main className="page">
      <header className="topbar">
        <div>
          <p className="eyebrow">Outscore Advisory Group</p>
          <h1>Profit Admin</h1>
        </div>
        <button className="icon-button" onClick={loadDashboard} type="button" title="Refresh dashboard">
          <RefreshCw size={18} aria-hidden="true" />
        </button>
      </header>

      {status === "error" ? <div className="error">{error}</div> : null}

      <section className="stats-grid" aria-label="Company GP">
        <Stat
          icon={Gauge}
          label="Company GP"
          value={formatPct(company.latest_month_gp_pct)}
          detail={`${monthLabel(company.latest_period_month)} · ${formatMoney(company.latest_month_gp_amount)}`}
          tone={company.gate_passed ? "good" : "warn"}
        />
        <Stat
          icon={CheckCircle2}
          label="Quarter Gate"
          value={company.gate_passed ? "Passed" : "Open"}
          detail={`${formatPct(company.latest_quarter_gp_pct)} vs ${formatPct(company.company_gate_gp_pct)} gate`}
          tone={company.gate_passed ? "good" : "warn"}
        />
        <Stat
          icon={CircleDollarSign}
          label="Recognized"
          value={formatMoney(company.recognized_revenue_amount)}
          detail={`${company.recognized_revenue_event_count ?? 0} revenue events`}
        />
        <Stat
          icon={ClipboardCheck}
          label="Pending"
          value={formatMoney(company.pending_revenue_amount)}
          detail={`${company.fc_ready_trigger_count ?? 0} ready FC triggers`}
        />
      </section>

      <section className="panel">
        <div className="panel-title">
          <TableProperties size={18} aria-hidden="true" />
          <h2>Per-Client GP</h2>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Period</th>
                <th>Client</th>
                <th>Service</th>
                <th>Owner</th>
                <th>Revenue</th>
                <th>Labor</th>
                <th>GP</th>
                <th>GP %</th>
              </tr>
            </thead>
            <tbody>
              {(snapshot?.client_gp ?? []).slice(0, 40).map((row, index) => (
                <tr key={`${row.period_month}-${row.anchor_relationship_id}-${row.macro_service_type}-${index}`}>
                  <td>{monthLabel(row.period_month)}</td>
                  <td>{row.anchor_client_business_name ?? "Unmatched"}</td>
                  <td>{row.macro_service_type ?? "other"}</td>
                  <td>{row.primary_owner_staff_name ?? "Unassigned"}</td>
                  <td>{formatMoney(row.recognized_revenue_amount)}</td>
                  <td>{formatMoney(row.matched_labor_cost)}</td>
                  <td>{formatMoney(row.gp_amount)}</td>
                  <td>{formatPct(row.gp_pct)}</td>
                </tr>
              ))}
              {snapshot?.client_gp?.length ? null : <EmptyRow colSpan={8} label="No client GP rows loaded" />}
            </tbody>
          </table>
        </div>
      </section>

      <section className="split">
        <div className="panel">
          <div className="panel-title">
            <UsersRound size={18} aria-hidden="true" />
            <h2>Per-Staff GP</h2>
          </div>
          <div className="table-wrap compact">
            <table>
              <thead>
                <tr>
                  <th>Staff</th>
                  <th>Revenue</th>
                  <th>Labor</th>
                  <th>GP %</th>
                  <th>Clients</th>
                </tr>
              </thead>
              <tbody>
                {latestStaffRows.map((row) => (
                  <tr key={row.staff_name}>
                    <td>{row.staff_name}</td>
                    <td>{formatMoney(row.owned_recognized_revenue_amount)}</td>
                    <td>{formatMoney(row.owned_matched_labor_cost)}</td>
                    <td>{formatPct(row.owned_gp_pct)}</td>
                    <td>{row.client_service_count ?? 0}</td>
                  </tr>
                ))}
                {latestStaffRows.length ? null : <EmptyRow colSpan={5} label="No staff GP rows loaded" />}
              </tbody>
            </table>
          </div>
        </div>

        <div className="panel">
          <div className="panel-title">
            <UserRoundCheck size={18} aria-hidden="true" />
            <h2>Comp Ledger</h2>
          </div>
          <div className="table-wrap compact">
            <table>
              <thead>
                <tr>
                  <th>Period</th>
                  <th>Staff</th>
                  <th>Gross</th>
                  <th>Accrual</th>
                </tr>
              </thead>
              <tbody>
                {(snapshot?.comp_kicker_ledger ?? []).slice(0, 12).map((row) => (
                  <tr key={`${row.period_month}-${row.staff_name}`}>
                    <td>{monthLabel(row.period_month)}</td>
                    <td>{row.staff_name}</td>
                    <td>{formatMoney(row.gross_kicker_amount)}</td>
                    <td>{formatMoney(row.kicker_accrual_amount)}</td>
                  </tr>
                ))}
                {snapshot?.comp_kicker_ledger?.length ? null : <EmptyRow colSpan={4} label="No comp rows loaded" />}
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <section className="split">
        <div className="panel">
          <div className="panel-title">
            <AlertTriangle size={18} aria-hidden="true" />
            <h2>W2 Watch</h2>
          </div>
          <div className="table-wrap compact">
            <table>
              <thead>
                <tr>
                  <th>Staff</th>
                  <th>Status</th>
                  <th>Annualized</th>
                  <th>Avg Hrs/Wk</th>
                </tr>
              </thead>
              <tbody>
                {(snapshot?.w2_candidates ?? []).map((row) => (
                  <tr key={`${row.period_month}-${row.staff_name}`}>
                    <td>{row.staff_name}</td>
                    <td>{row.w2_flag_status}</td>
                    <td>{formatMoney(row.annualized_contractor_cost)}</td>
                    <td>{Number(row.avg_weekly_hours ?? 0).toFixed(1)}</td>
                  </tr>
                ))}
                {snapshot?.w2_candidates?.length ? null : <EmptyRow colSpan={4} label="No W2 candidates" />}
              </tbody>
            </table>
          </div>
        </div>

        <div className="panel">
          <div className="panel-title">
            <ClipboardCheck size={18} aria-hidden="true" />
            <h2>FC Trigger Queue</h2>
          </div>
          <div className="queue-list">
            {(snapshot?.fc_trigger_queue ?? []).slice(0, 8).map((row, index) => (
              <article className="queue-item" key={`${row.completed_at}-${row.client_name}-${index}`}>
                <strong>{row.client_name ?? "Unmatched client"}</strong>
                <span>{row.task_title}</span>
                <em>{row.approval_status} · {row.trigger_load_status}</em>
              </article>
            ))}
            {snapshot?.fc_trigger_queue?.length ? null : <p className="empty">No FC trigger rows loaded</p>}
          </div>
        </div>
      </section>
    </main>
  );
}

export default App;

