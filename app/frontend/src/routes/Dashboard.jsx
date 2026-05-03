import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  CircleDollarSign,
  ClipboardCheck,
  Gauge,
  Landmark,
  RefreshCw,
  TableProperties,
  UserRoundCheck,
  UsersRound,
} from "lucide-react";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const endpoint = `${apiBase}/profit/admin/dashboard`;
const prepaidBalancesEndpoint = `${apiBase}/profit/admin/prepaid/balances`;
const prepaidLedgerEndpoint = `${apiBase}/profit/admin/prepaid/ledger`;

const SERVICE_CATEGORY_LABEL = {
  tax_deferred_revenue: "Tax Deferred",
  pending_recognition_trigger: "Trigger Backlog",
  recognized: "Recognized",
};

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

function formatRatio(value) {
  return value == null ? "No data" : pct.format(Number(value));
}

function monthLabel(value) {
  if (!value) return "n/a";
  return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    year: "numeric",
  });
}

function dateLabel(value) {
  if (!value) return "n/a";
  const dateValue = String(value).includes("T") ? value : `${value}T00:00:00`;
  return new Date(dateValue).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function dateTimeLabel(value) {
  if (!value) return "n/a";
  return new Date(value).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
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

function withRunningBalances(rows) {
  let running = 0;
  return [...rows]
    .sort((a, b) => String(a.event_at ?? "").localeCompare(String(b.event_at ?? "")))
    .map((row) => {
      running += Number(row.amount_delta ?? 0);
      return { ...row, running_balance: running };
    })
    .sort((a, b) => String(b.event_at ?? "").localeCompare(String(a.event_at ?? "")));
}

const triggerBacklogFallback = "Delivered services with no recognition trigger loaded — not a QBO liability entry. Clears when FC completion triggers are approved.";

function PrepaidLiabilityTile({ prepaidLiability }) {
  const summary = prepaidLiability?.summary ?? {};
  const isLoaded = prepaidLiability?.collection_feed_status === "loaded";

  if (!isLoaded) {
    return (
      <section className="stat stat-warn prepaid-stat">
        <div className="stat-icon">
          <Landmark size={18} aria-hidden="true" />
        </div>
        <div className="prepaid-stat-body">
          <p>Prepaid Liability · point-in-time</p>
          <strong>Collection feed not yet loaded</strong>
          <span>Deferred Revenue JE not ready</span>
        </div>
      </section>
    );
  }

  return (
    <section className="stat prepaid-stat">
      <div className="stat-icon">
        <Landmark size={18} aria-hidden="true" />
      </div>
      <div className="prepaid-stat-body">
        <p>Prepaid Liability · point-in-time</p>
        <div className="prepaid-stat-row" title="Record this exact amount as Deferred Revenue in QuickBooks. Tax retainers held until return is filed or extended.">
          <span>Tax Deferred Revenue</span>
          <strong>{formatMoney(summary.tax_deferred_revenue_balance)}</strong>
        </div>
        <div className="prepaid-stat-row" title={summary.trigger_backlog_note ?? triggerBacklogFallback}>
          <span>Trigger Backlog</span>
          <strong>{formatMoney(summary.trigger_backlog_balance)}</strong>
        </div>
        <div className="prepaid-stat-row reference" title="Sum of both buckets. Do not record this as a single QBO entry.">
          <span>Total reference</span>
          <strong>{formatMoney(summary.total_prepaid_liability_balance)}</strong>
        </div>
        <small>
          {summary.last_updated
            ? `Current balance as of ${dateTimeLabel(summary.last_updated)}`
            : "Current point-in-time balance"}
        </small>
      </div>
    </section>
  );
}

function RatioSummary({ ratios }) {
  const items = [
    ["Client Labor LER", ratios?.client_labor_ler],
    ["Admin Labor LER", ratios?.admin_labor_ler],
    ["Unmatched Labor LER", ratios?.unmatched_labor_ler],
    ["Total Labor LER", ratios?.total_labor_ler],
    ["Gross Margin %", ratios?.gross_margin_pct],
    ["Client-Matched %", ratios?.client_matched_pct],
    ["Admin Load %", ratios?.admin_load_pct],
  ];

  return (
    <section className="panel ratio-panel" aria-label="Ratio Summary">
      <div className="panel-title">
        <Gauge size={18} aria-hidden="true" />
        <h2>Ratio Summary</h2>
      </div>
      <div className="ratio-grid">
        {items.map(([label, value]) => (
          <div className="ratio-item" key={label}>
            <span>{label}</span>
            <strong>{formatRatio(value)}</strong>
          </div>
        ))}
      </div>
    </section>
  );
}

function ClientBadges({ row }) {
  const revenue = Number(row.recognized_revenue_amount ?? 0);
  const labor = Number(row.matched_labor_cost ?? 0);
  const gp = Number(row.gp_amount ?? 0);
  const service = row.macro_service_type ?? "other";
  const badges = [];

  if (revenue === 0 && labor > 0) badges.push("Labor no revenue");
  if (gp < 0) badges.push("Negative GP");
  if (service === "other") badges.push("Review service");

  if (!badges.length) return null;

  return (
    <div className="badge-row">
      {badges.map((badge) => (
        <span className="review-badge" key={badge}>
          {badge}
        </span>
      ))}
    </div>
  );
}

function PrepaidLiabilityPanel({
  prepaidLiability,
  balances,
  prepaidFilter,
  setPrepaidFilter,
  selectedRow,
  onSelectRow,
  ledgerRows,
}) {
  const summary = prepaidLiability?.summary ?? {};
  const filterItems = [
    ["all", "All"],
    ["tax", SERVICE_CATEGORY_LABEL.tax_deferred_revenue],
    ["trigger", SERVICE_CATEGORY_LABEL.pending_recognition_trigger],
  ];

  return (
    <section className="panel prepaid-panel">
      <div className="panel-title">
        <Landmark size={18} aria-hidden="true" />
        <h2>Prepaid Liability Drilldown</h2>
      </div>
      <p className="panel-note">
        Tax Deferred Revenue: {formatMoney(summary.tax_deferred_revenue_balance)}. Record this as Deferred Revenue in QBO.
        Trigger Backlog: {formatMoney(summary.trigger_backlog_balance)}. Clears when completion triggers are approved; not a QBO entry.
      </p>
      <div className="filter-row" aria-label="Prepaid liability filters">
        {filterItems.map(([value, label]) => (
          <button
            className={prepaidFilter === value ? "filter-chip active" : "filter-chip"}
            key={value}
            onClick={() => setPrepaidFilter(value)}
            type="button"
          >
            {label}
          </button>
        ))}
      </div>
      <div className="split prepaid-split">
        <div className="table-wrap compact">
          <table>
            <thead>
              <tr>
                <th>Client</th>
                <th>Service category</th>
                <th>Macro service</th>
                <th>Balance</th>
                <th>Last Updated</th>
              </tr>
            </thead>
            <tbody>
              {balances.map((row, index) => (
                <tr
                  className={selectedRow === row ? "selected-row" : ""}
                  key={`${row.anchor_relationship_id}-${row.macro_service_type}-${row.service_category}-${index}`}
                  onClick={() => onSelectRow(row)}
                >
                  <td>{row.anchor_client_business_name ?? "Unmatched"}</td>
                  <td>{SERVICE_CATEGORY_LABEL[row.service_category] ?? row.service_category ?? "n/a"}</td>
                  <td>{row.macro_service_type ?? "n/a"}</td>
                  <td>{formatMoney(row.balance)}</td>
                  <td>{dateLabel(row.last_updated)}</td>
                </tr>
              ))}
              {balances.length ? null : <EmptyRow colSpan={5} label="No prepaid liability balances loaded" />}
            </tbody>
          </table>
        </div>
        <div className="table-wrap compact ledger-table-wrap">
          <p className="ledger-note">
            QBO journal entry reconciliation trail. Cash collected increases the balance; revenue recognized draws it down.
          </p>
          <table>
            <thead>
              <tr>
                <th>Date</th>
                <th>Type</th>
                <th>Amount</th>
                <th>Source ref</th>
                <th>Running balance</th>
              </tr>
            </thead>
            <tbody>
              {ledgerRows.map((row, index) => (
                <tr key={`${row.event_at}-${row.revenue_event_key}-${row.ledger_entry_type}-${index}`}>
                  <td>{dateLabel(row.event_at)}</td>
                  <td>{row.ledger_entry_type}</td>
                  <td>{formatMoney(row.amount_delta)}</td>
                  <td>{row.ledger_entry_type === "cash_collected" ? row.source_payment_id : row.revenue_event_key}</td>
                  <td>{formatMoney(row.running_balance)}</td>
                </tr>
              ))}
              {ledgerRows.length ? null : <EmptyRow colSpan={5} label="Select a client balance to load the audit ledger" />}
            </tbody>
          </table>
        </div>
      </div>
    </section>
  );
}

function CompanyGpTrend({ rows }) {
  const trendRows = rows ?? [];
  const validRows = trendRows.filter((row) => row.gp_pct != null);
  const width = 680;
  const height = 180;
  const padding = 24;
  const maxPct = Math.max(0.7, ...validRows.map((row) => Number(row.gp_pct)));
  const minPct = Math.min(0, ...validRows.map((row) => Number(row.gp_pct)));
  const range = maxPct - minPct || 1;
  const points = validRows.map((row, index) => {
    const x = validRows.length === 1
      ? width / 2
      : padding + (index * (width - padding * 2)) / (validRows.length - 1);
    const y = height - padding - ((Number(row.gp_pct) - minPct) / range) * (height - padding * 2);
    return { ...row, x, y };
  });
  const line = points.map((point) => `${point.x},${point.y}`).join(" ");

  return (
    <section className="panel trend-panel">
      <div className="panel-title">
        <Gauge size={18} aria-hidden="true" />
        <h2>Company GP Trend</h2>
      </div>
      <p className="panel-note">Last 12 available months · recognition-basis GP %</p>
      {points.length ? (
        <div className="trend-chart">
          <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Company GP Trend">
            <line className="trend-grid-line" x1={padding} x2={width - padding} y1={padding} y2={padding} />
            <line className="trend-grid-line" x1={padding} x2={width - padding} y1={height - padding} y2={height - padding} />
            <polyline className="trend-line" points={line} />
            {points.map((point) => (
              <g key={point.period_month}>
                <circle className="trend-point" cx={point.x} cy={point.y} r="4" />
                <text className="trend-label" x={point.x} y={height - 6} textAnchor="middle">
                  {monthLabel(point.period_month)}
                </text>
                <text className="trend-value" x={point.x} y={Math.max(14, point.y - 9)} textAnchor="middle">
                  {formatPct(point.gp_pct)}
                </text>
              </g>
            ))}
          </svg>
        </div>
      ) : (
        <p className="empty panel-empty">No Company GP trend rows loaded</p>
      )}
    </section>
  );
}

function Dashboard() {
  const [snapshot, setSnapshot] = useState(null);
  const [selectedPeriod, setSelectedPeriod] = useState("");
  const [status, setStatus] = useState("loading");
  const [error, setError] = useState("");
  const [prepaidBalances, setPrepaidBalances] = useState([]);
  const [prepaidFilter, setPrepaidFilter] = useState("all");
  const [selectedPrepaidRow, setSelectedPrepaidRow] = useState(null);
  const [prepaidLedgerRows, setPrepaidLedgerRows] = useState([]);

  async function loadDashboard(period = selectedPeriod) {
    setStatus("loading");
    setError("");
    try {
      const requestUrl = period ? `${endpoint}?period=${encodeURIComponent(period)}` : endpoint;
      const response = await fetch(requestUrl);
      if (!response.ok) {
        throw new Error(`Dashboard request failed: ${response.status}`);
      }
      const payload = await response.json();
      setSnapshot(payload);
      if (!period && payload.selected_period_month) {
        setSelectedPeriod(payload.selected_period_month);
      }
      await loadPrepaidBalances();
      setStatus("ready");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Dashboard request failed");
      setStatus("error");
    }
  }

  async function loadPrepaidBalances() {
    const response = await fetch(prepaidBalancesEndpoint);
    if (!response.ok) {
      throw new Error(`Prepaid balances request failed: ${response.status}`);
    }
    const payload = await response.json();
    setPrepaidBalances(payload.rows ?? []);
  }

  async function loadPrepaidLedger(row) {
    setSelectedPrepaidRow(row);
    const params = new URLSearchParams({
      anchor_relationship_id: row.anchor_relationship_id,
      macro_service_type: row.macro_service_type,
    });
    const response = await fetch(`${prepaidLedgerEndpoint}?${params.toString()}`);
    if (!response.ok) {
      throw new Error(`Prepaid ledger request failed: ${response.status}`);
    }
    const payload = await response.json();
    setPrepaidLedgerRows(withRunningBalances(payload.rows ?? []));
  }

  useEffect(() => {
    loadDashboard();
  }, []);

  const company = snapshot?.company ?? {};
  const staffRows = useMemo(() => snapshot?.staff_gp ?? [], [snapshot]);
  const availablePeriods = snapshot?.available_periods ?? [];
  const fixedWindows = snapshot?.fixed_windows ?? {};
  const prepaidLiability = snapshot?.prepaid_liability ?? {};
  const fcQueueCount = snapshot?.fc_trigger_queue?.length ?? 0;
  const visiblePrepaidBalances = useMemo(
    () => prepaidBalances
      .filter((row) => row.service_category !== "recognized")
      .filter((row) => {
        if (prepaidFilter === "tax") return row.service_category === "tax_deferred_revenue";
        if (prepaidFilter === "trigger") return row.service_category === "pending_recognition_trigger";
        return true;
      }),
    [prepaidBalances, prepaidFilter],
  );

  return (
    <main className="page">
      <header className="topbar">
        <div>
          <p className="eyebrow">Outscore Advisory Group</p>
          <h1>Profit Admin</h1>
        </div>
        <div className="topbar-actions">
          <label className="period-control">
            <span>Period</span>
            <select
              value={selectedPeriod}
              onChange={(event) => {
                setSelectedPeriod(event.target.value);
                loadDashboard(event.target.value);
              }}
            >
              {availablePeriods.map((row) => (
                <option key={row.period_month} value={row.period_month}>
                  {monthLabel(row.period_month)}
                </option>
              ))}
            </select>
          </label>
          <button className="icon-button" onClick={() => loadDashboard(selectedPeriod)} type="button" title="Refresh dashboard">
            <RefreshCw size={18} aria-hidden="true" />
          </button>
        </div>
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
          detail={`${company.pending_revenue_event_count ?? 0} pending revenue events`}
        />
        <PrepaidLiabilityTile prepaidLiability={prepaidLiability} />
      </section>

      <PrepaidLiabilityPanel
        balances={visiblePrepaidBalances}
        ledgerRows={prepaidLedgerRows}
        onSelectRow={loadPrepaidLedger}
        prepaidFilter={prepaidFilter}
        prepaidLiability={prepaidLiability}
        selectedRow={selectedPrepaidRow}
        setPrepaidFilter={setPrepaidFilter}
      />

      <CompanyGpTrend rows={snapshot?.trends?.company_gp} />

      <RatioSummary ratios={snapshot?.ratio_summary} />

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
                  <td>
                    <strong className="table-primary">{row.anchor_client_business_name ?? "Unmatched"}</strong>
                    <ClientBadges row={row} />
                  </td>
                  <td>{row.macro_service_type ?? "other"}</td>
                  <td>{row.primary_owner_staff_name ?? "Needs owner mapping"}</td>
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
                {staffRows.map((row) => (
                  <tr key={row.staff_name}>
                    <td>{row.staff_name}</td>
                    <td>{formatMoney(row.owned_recognized_revenue_amount)}</td>
                    <td>{formatMoney(row.owned_matched_labor_cost)}</td>
                    <td>{formatPct(row.owned_gp_pct)}</td>
                    <td>{row.client_service_count ?? 0}</td>
                  </tr>
                ))}
                {staffRows.length ? null : <EmptyRow colSpan={5} label="No staff GP rows loaded" />}
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
            <h2>W2 Watch · Trailing 8-month window</h2>
          </div>
          <p className="panel-note">{fixedWindows.w2_candidates}</p>
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
            <h2>FC Trigger Queue · Live queue ({fcQueueCount})</h2>
          </div>
          <p className="panel-note">{fixedWindows.fc_trigger_queue}</p>
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

export default Dashboard;
