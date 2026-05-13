import { useEffect, useMemo, useState } from "react";
import { RefreshCw } from "lucide-react";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const itemsEndpoint = `${apiBase}/profit/admin/weekly-review/items`;

const ITEM_TYPE_LABELS = {
  MANUAL_INVOICE_PENDING: "Manual Invoice Pending",
  SLA_BREACHED: "SLA Breached",
  MANUAL_RECOGNITION_PENDING: "Manual Recognition Pending",
  PIPELINE_RUN_FAILED: "Pipeline Run Failed",
};

const VERDICT_FILTERS = [
  { code: "SLA_BREACHED", label: "SLA" },
  { code: "MANUAL_INVOICE_PENDING", label: "Manual Invoice" },
  { code: "MANUAL_RECOGNITION_PENDING", label: "Manual Recognition" },
  { code: "PIPELINE_RUN_FAILED", label: "Pipeline" },
];

const SORT_KEYS = {
  rank: "rank",
  client_name: "client_name",
  service_name: "service_name",
  verdict_code: "verdict_code",
};

function itemTypeBadge(itemType) {
  const normalized = String(itemType ?? "unknown");
  const label = ITEM_TYPE_LABELS[normalized] ?? normalized.replaceAll("_", " ");
  const variant = `weekly-review-badge-${normalized.toLowerCase().replaceAll("_", "-")}`;
  return <span className={`weekly-review-badge ${variant}`}>{label}</span>;
}

function attributionBadge(row, { compact }) {
  if (row.label_unresolved) {
    const text = row.label ?? "Unresolved label";
    return (
      <span
        className="weekly-review-label-badge-unresolved"
        title="Label did not resolve to a known FC client; treat as annotation."
      >
        {"\u26A0 "}{text}
      </span>
    );
  }
  if (
    row.label &&
    row.agreement_client_business_name &&
    row.agreement_client_business_name !== row.client_name
  ) {
    const tipText = `via ${row.agreement_client_business_name}`;
    if (compact) {
      return (
        <span
          className="weekly-review-label-info-icon"
          title={`${tipText} (attributed via labeled-service rule from the agreement holder)`}
          aria-label={tipText}
        >
          {"\u24D8"}
        </span>
      );
    }
    return (
      <span
        className="weekly-review-label-badge-via"
        title="Attributed via labeled-service rule from the agreement holder."
      >
        via {row.agreement_client_business_name}
      </span>
    );
  }
  return null;
}

function currencyValue(value) {
  if (value === null || value === undefined || value === "") return "-";
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return "-";
  return numeric.toLocaleString("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
}

function textValue(...values) {
  const found = values.find((v) => v !== null && v !== undefined && v !== "");
  return found === undefined ? "-" : found;
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

function breachStateBadge(breachState) {
  if (!breachState) return "-";
  const normalized = String(breachState);
  const className = `weekly-review-breach-badge weekly-review-breach-${normalized.replaceAll("_", "-")}`;
  const label = normalized === "at_risk" ? "at risk" : normalized;
  return <span className={className}>{label}</span>;
}

function macroChip(value) {
  if (!value) return null;
  const normalized = String(value).toLowerCase();
  return (
    <span className={`weekly-review-macro-chip weekly-review-macro-${normalized}`}>
      {normalized}
    </span>
  );
}

function pipelineRunIdFromClientName(clientName) {
  if (!clientName) return null;
  const match = String(clientName).match(/^System:\s*Pipeline\s+(.+)$/i);
  return match ? match[1].trim() : null;
}

function SlaCompact({ row }) {
  const parts = [];
  if (row.breach_state) parts.push(row.breach_state.replaceAll("_", " "));
  if (row.breach_age_days !== null && row.breach_age_days !== undefined) {
    parts.push(`${row.breach_age_days} days overdue`);
  }
  if (row.assigned_staff_name) parts.push(row.assigned_staff_name);
  return <span className="weekly-review-compact-line">{parts.join(" / ") || "-"}</span>;
}

function ManualInvoiceCompact({ row }) {
  const parts = [];
  const state = row.invoice_state ?? "no_invoice";
  parts.push(state);
  const rev = row.est_annual_revenue ?? row.estimated_annual_revenue;
  if (rev !== null && rev !== undefined && rev !== "") {
    parts.push(`${currencyValue(rev)} est`);
  }
  return <span className="weekly-review-compact-line">{parts.join(" / ")}</span>;
}

function ManualRecognitionCompact({ row }) {
  const parts = [];
  if (row.service_name) parts.push(row.service_name);
  if (row.age_days !== null && row.age_days !== undefined) {
    parts.push(`${row.age_days} days stuck`);
  }
  return <span className="weekly-review-compact-line">{parts.join(" / ") || "-"}</span>;
}

function PipelineFailureCompact({ row }) {
  const age = row.age_days;
  if (age === null || age === undefined) {
    return <span className="weekly-review-compact-line">Pipeline failed</span>;
  }
  const unit = Number(age) === 1 ? "day" : "days";
  return <span className="weekly-review-compact-line">Failed {age} {unit} ago</span>;
}

function SlaDetails({ row }) {
  const staff = textValue(row.assigned_staff_name);
  const source = row.staff_source ? ` (${row.staff_source})` : "";
  const overdueText =
    row.breach_age_days !== null && row.breach_age_days !== undefined
      ? `${row.breach_age_days} days overdue`
      : null;
  return (
    <div className="weekly-review-sla-details">
      <div>{breachStateBadge(row.breach_state)}</div>
      {overdueText ? (
        <div className="weekly-review-sla-overdue">{overdueText}</div>
      ) : null}
      <div className="weekly-review-sla-target">
        Target: {formatDate(row.target_date)}
      </div>
      <div className="weekly-review-sla-staff">
        Staff: {staff}{source}
      </div>
      {row.work_age_days !== null && row.work_age_days !== undefined ? (
        <div className="weekly-review-sla-staff">
          Work age: {row.work_age_days} days
        </div>
      ) : null}
      {row.latest_workflow_status ? (
        <div className="weekly-review-sla-staff">
          Workflow: {row.latest_workflow_status}
        </div>
      ) : null}
      {row.label && row.agreement_client_business_name ? (
        <div className="weekly-review-sla-staff">
          Attribution: via {row.agreement_client_business_name}
        </div>
      ) : null}
    </div>
  );
}

function ManualInvoiceDetails({ row }) {
  return (
    <div className="weekly-review-manual-details">
      <div>{textValue(row.invoice_state)}</div>
      <div className="weekly-review-manual-rev">
        Est. annual rev: {currencyValue(row.est_annual_revenue ?? row.estimated_annual_revenue)}
      </div>
      {row.age_days !== null && row.age_days !== undefined ? (
        <div className="weekly-review-manual-rev">Age: {row.age_days} days</div>
      ) : null}
    </div>
  );
}

function ManualRecognitionDetails({ row }) {
  return (
    <div className="weekly-review-manual-details">
      <div className="weekly-review-manual-rev">
        Service: {textValue(row.service_name)}
        {row.macro_service_type ? <> {macroChip(row.macro_service_type)}</> : null}
      </div>
      {row.age_days !== null && row.age_days !== undefined ? (
        <div className="weekly-review-manual-rev">
          {row.age_days} days stuck
        </div>
      ) : null}
      {row.estimated_annual_revenue !== null
        && row.estimated_annual_revenue !== undefined
        && row.estimated_annual_revenue !== "" ? (
        <div className="weekly-review-manual-rev">
          Est. annual rev: {currencyValue(row.estimated_annual_revenue)}
        </div>
      ) : null}
      {row.fc_tag ? (
        <div className="weekly-review-manual-rev">FC tag: {row.fc_tag}</div>
      ) : null}
    </div>
  );
}

function PipelineFailureDetails({ row }) {
  const runId = pipelineRunIdFromClientName(row.client_name);
  return (
    <div className="weekly-review-manual-details">
      <div className="weekly-review-manual-rev">
        Pipeline run {runId ?? "(unknown)"} failed
      </div>
      {row.age_days !== null && row.age_days !== undefined ? (
        <div className="weekly-review-manual-rev">
          {row.age_days} {Number(row.age_days) === 1 ? "day" : "days"} since failure
        </div>
      ) : null}
      {row.action_url ? (
        <div className="weekly-review-manual-rev">
          <a
            className="weekly-review-action-link"
            href={row.action_url}
            rel="noopener noreferrer"
            target="_blank"
          >
            View run details
          </a>
        </div>
      ) : null}
    </div>
  );
}

function DetailsCompact({ row }) {
  switch (row.verdict_code) {
    case "SLA_BREACHED":
      return <SlaCompact row={row} />;
    case "MANUAL_RECOGNITION_PENDING":
      return <ManualRecognitionCompact row={row} />;
    case "PIPELINE_RUN_FAILED":
      return <PipelineFailureCompact row={row} />;
    case "MANUAL_INVOICE_PENDING":
    default:
      return <ManualInvoiceCompact row={row} />;
  }
}

function DetailsExpanded({ row }) {
  switch (row.verdict_code) {
    case "SLA_BREACHED":
      return <SlaDetails row={row} />;
    case "MANUAL_RECOGNITION_PENDING":
      return <ManualRecognitionDetails row={row} />;
    case "PIPELINE_RUN_FAILED":
      return <PipelineFailureDetails row={row} />;
    case "MANUAL_INVOICE_PENDING":
    default:
      return <ManualInvoiceDetails row={row} />;
  }
}

function sortKey(row, column) {
  switch (column) {
    case "rank":
      return Number(row.sort_rank ?? Number.POSITIVE_INFINITY);
    case "client_name":
      return String(row.client_name ?? row.anchor_client_business_name ?? "").toLowerCase();
    case "service_name":
      return String(row.service_name ?? row.services ?? "").toLowerCase();
    case "verdict_code":
      return String(row.item_type ?? row.verdict_code ?? "").toLowerCase();
    default:
      return 0;
  }
}

function compareRows(a, b, column, direction) {
  const av = sortKey(a, column);
  const bv = sortKey(b, column);
  let cmp;
  if (typeof av === "number" && typeof bv === "number") {
    cmp = av - bv;
  } else {
    cmp = String(av).localeCompare(String(bv));
  }
  return direction === "asc" ? cmp : -cmp;
}

function SortHeader({ label, column, sortColumn, sortDirection, onSort }) {
  const active = sortColumn === column;
  const arrow = active ? (sortDirection === "asc" ? "\u2191" : "\u2193") : "";
  return (
    <th
      aria-sort={active ? (sortDirection === "asc" ? "ascending" : "descending") : "none"}
      className="weekly-review-sort-header"
      onClick={() => onSort(column)}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          onSort(column);
        }
      }}
      role="columnheader"
      tabIndex={0}
    >
      {label}
      <span className="weekly-review-sort-arrow">{arrow}</span>
    </th>
  );
}

function WeeklyReviewRow({ row, index, onMarkReviewed, onUnreview, onSnooze, onUnsnooze, expanded, onToggleExpanded, today }) {
  const verdictCode = row.verdict_code ?? row.item_type ?? "MANUAL_INVOICE_PENDING";
  const isSystemAlert = verdictCode === "PIPELINE_RUN_FAILED";
  const badge = attributionBadge(row, { compact: !expanded });
  const rowId = row.classification_id ?? `idx-${index}`;
  const isReviewed = row.reviewed_at != null;
  const isSnoozed = row.snoozed_until != null && row.snoozed_until >= today;
  const rowClasses = [
    isReviewed ? "weekly-review-row-reviewed" : "",
    isSnoozed ? "weekly-review-row-snoozed" : "",
  ].filter(Boolean).join(" ");
  return (
    <tr className={rowClasses || undefined} key={row.classification_id ?? index}>
      <td>
        <button
          aria-expanded={expanded}
          aria-label={expanded ? "Collapse details" : "Expand details"}
          className="weekly-review-disclosure"
          onClick={() => onToggleExpanded(rowId)}
          title={expanded ? "Collapse details" : "Expand details"}
          type="button"
        >
          {expanded ? "\u25BC" : "\u25B6"}
        </button>
        <span className="weekly-review-rank-num">{row.sort_rank ?? index + 1}</span>
      </td>
      <td>
        {isSystemAlert ? (
          <span className="weekly-review-system-alert">System Alert</span>
        ) : (
          <span className="weekly-review-primary">
            {textValue(row.client_name, row.anchor_client_business_name)}
            {badge && row.label_unresolved ? <> {badge}</> : null}
            {badge && !row.label_unresolved && !expanded ? <> {badge}</> : null}
          </span>
        )}
      </td>
      <td>{textValue(row.service_name, row.services)}</td>
      <td>
        <div className="weekly-review-type-cell">
          {itemTypeBadge(verdictCode)}
          {expanded && badge && !row.label_unresolved ? badge : null}
        </div>
      </td>
      <td>
        {expanded ? <DetailsExpanded row={row} /> : <DetailsCompact row={row} />}
      </td>
      <td>
        {row.action_url ? (
          <a
            className="weekly-review-action-link"
            href={row.action_url}
            rel={isSystemAlert ? undefined : "noopener noreferrer"}
            target={isSystemAlert ? "_self" : "_blank"}
          >
            {isSystemAlert ? "View run details" : "Open work item"}
          </a>
        ) : (
          "-"
        )}
      </td>
      <td className="weekly-review-controls-cell">
        {isReviewed ? (
          <span className="weekly-review-state-pill weekly-review-state-reviewed" title={`Reviewed ${row.reviewed_at}`}>
            Reviewed
          </span>
        ) : null}
        {isSnoozed ? (
          <span className="weekly-review-state-pill weekly-review-state-snoozed" title={`Snoozed until ${row.snoozed_until}`}>
            Snoozed until {row.snoozed_until}
          </span>
        ) : null}
        {!isReviewed ? (
          <button
            className="btn btn-secondary weekly-review-btn-sm"
            disabled={row.classification_id == null}
            onClick={() => onMarkReviewed(row.classification_id)}
            title={row.classification_id == null
              ? "Available after next pipeline run creates the classification"
              : "Mark this item as reviewed"}
            type="button"
          >
            Mark reviewed
          </button>
        ) : (
          <button
            className="btn btn-secondary weekly-review-btn-sm"
            disabled={row.classification_id == null}
            onClick={() => onUnreview(row.classification_id)}
            title="Bring this item back to the actionable queue — underlying issue not yet resolved"
            type="button"
          >
            Un-review
          </button>
        )}
        {!isSnoozed ? (
          <button
            className="btn btn-secondary weekly-review-btn-sm"
            disabled={row.classification_id == null}
            onClick={() => onSnooze(row.classification_id)}
            title={row.classification_id == null
              ? "Available after next pipeline run creates the classification"
              : "Snooze this item for 7 days"}
            type="button"
          >
            Snooze 7 days
          </button>
        ) : (
          <button
            className="btn btn-secondary weekly-review-btn-sm"
            disabled={row.classification_id == null}
            onClick={() => onUnsnooze(row.classification_id)}
            title="Bring this item back into the actionable queue"
            type="button"
          >
            Un-snooze
          </button>
        )}
      </td>
    </tr>
  );
}

function TableHead({ sortColumn, sortDirection, onSort }) {
  return (
    <thead>
      <tr>
        <SortHeader
          column={SORT_KEYS.rank}
          label="Rank"
          onSort={onSort}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
        />
        <SortHeader
          column={SORT_KEYS.client_name}
          label="Client"
          onSort={onSort}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
        />
        <SortHeader
          column={SORT_KEYS.service_name}
          label="Services"
          onSort={onSort}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
        />
        <SortHeader
          column={SORT_KEYS.verdict_code}
          label="Type"
          onSort={onSort}
          sortColumn={sortColumn}
          sortDirection={sortDirection}
        />
        <th>Details</th>
        <th>Action</th>
        <th>Controls</th>
      </tr>
    </thead>
  );
}

export default function WeeklyReview() {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  // V0.7.D-2 hotfix: unified "show non-actionable" toggle covers BOTH reviewed
  // and snoozed items. Separate "Snoozed" chip in the filter row also scopes
  // to snoozed-only, with an Un-snooze button per row.
  const [includeNonActionable, setIncludeNonActionable] = useState(false);
  const [sortColumn, setSortColumn] = useState("rank");
  const [sortDirection, setSortDirection] = useState("asc");
  const [viewMode, setViewMode] = useState("flat");
  const [expandedGroups, setExpandedGroups] = useState({});
  const [verdictFilter, setVerdictFilter] = useState(null);
  const [showSnoozedOnly, setShowSnoozedOnly] = useState(false);
  const [expandedRows, setExpandedRows] = useState(() => new Set());

  async function loadItems(withNonActionable) {
    setLoading(true);
    setError("");
    try {
      const url = withNonActionable
        ? `${itemsEndpoint}?include_reviewed=true&include_snoozed=true`
        : itemsEndpoint;
      const response = await fetch(url);
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.detail?.message ?? `Weekly review request failed: ${response.status}`);
      }
      setItems(payload.items ?? payload.rows ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Weekly review request failed");
      setItems([]);
    } finally {
      setLoading(false);
    }
  }

  async function markReviewed(classificationId) {
    try {
      await fetch(
        `${apiBase}/profit/admin/weekly-review/items/${classificationId}/reviewed`,
        { method: "POST" },
      );
    } catch {
      // silently ignore; refresh will reflect server state
    }
    loadItems(includeNonActionable);
  }

  async function snoozeItem(classificationId) {
    try {
      await fetch(
        `${apiBase}/profit/admin/weekly-review/items/${classificationId}/snooze`,
        { method: "POST" },
      );
    } catch {
      // silently ignore; refresh will reflect server state
    }
    loadItems(includeNonActionable);
  }

  async function unsnoozeItem(classificationId) {
    try {
      await fetch(
        `${apiBase}/profit/admin/weekly-review/items/${classificationId}/unsnooze`,
        { method: "POST" },
      );
    } catch {
      // silently ignore; refresh will reflect server state
    }
    loadItems(includeNonActionable);
  }

  async function unreviewItem(classificationId) {
    try {
      await fetch(
        `${apiBase}/profit/admin/weekly-review/items/${classificationId}/unreview`,
        { method: "POST" },
      );
    } catch {
      // silently ignore; refresh will reflect server state
    }
    loadItems(includeNonActionable);
  }

  function handleToggleNonActionable() {
    const next = !includeNonActionable;
    setIncludeNonActionable(next);
    // Turning OFF also clears the Snoozed-only filter to avoid an empty queue
    if (!next) setShowSnoozedOnly(false);
    loadItems(next);
  }

  function handleRefresh() {
    loadItems(includeNonActionable);
  }

  function handleSort(column) {
    if (sortColumn === column) {
      setSortDirection((prev) => (prev === "asc" ? "desc" : "asc"));
    } else {
      setSortColumn(column);
      setSortDirection("asc");
    }
  }

  function toggleGroup(groupKey) {
    setExpandedGroups((prev) => ({ ...prev, [groupKey]: !prev[groupKey] }));
  }

  function toggleRowExpanded(rowId) {
    setExpandedRows((prev) => {
      const next = new Set(prev);
      if (next.has(rowId)) {
        next.delete(rowId);
      } else {
        next.add(rowId);
      }
      return next;
    });
  }

  const sortedItems = useMemo(() => {
    const arr = Array.isArray(items) ? items.slice() : [];
    arr.sort((a, b) => compareRows(a, b, sortColumn, sortDirection));
    return arr;
  }, [items, sortColumn, sortDirection]);

  const verdictCounts = useMemo(() => {
    const counts = { SLA_BREACHED: 0, MANUAL_INVOICE_PENDING: 0, MANUAL_RECOGNITION_PENDING: 0, PIPELINE_RUN_FAILED: 0 };
    for (const row of sortedItems) {
      const code = row.verdict_code ?? row.item_type;
      if (code && counts.hasOwnProperty(code)) {
        counts[code] += 1;
      }
    }
    return counts;
  }, [sortedItems]);

  const today = useMemo(() => new Date().toISOString().slice(0, 10), []);

  const snoozedCount = useMemo(
    () => sortedItems.filter((r) => r.snoozed_until && r.snoozed_until >= today).length,
    [sortedItems, today],
  );

  const filteredItems = useMemo(() => {
    let rows = sortedItems;
    if (verdictFilter) {
      rows = rows.filter((row) => (row.verdict_code ?? row.item_type) === verdictFilter);
    }
    if (showSnoozedOnly) {
      rows = rows.filter((row) => row.snoozed_until && row.snoozed_until >= today);
    }
    return rows;
  }, [sortedItems, verdictFilter, showSnoozedOnly, today]);

  const groupedItems = useMemo(() => {
    if (viewMode !== "grouped") return null;
    const groups = new Map();
    for (const row of filteredItems) {
      const key =
        row.agreement_client_business_name
        ?? row.client_name
        ?? row.anchor_client_business_name
        ?? "Unassigned";
      if (!groups.has(key)) {
        groups.set(key, []);
      }
      groups.get(key).push(row);
    }
    return Array.from(groups.entries()).map(([key, rows]) => {
      const breachCount = rows.filter(
        (row) => row.verdict_code === "SLA_BREACHED",
      ).length;
      return { key, rows, breachCount };
    });
  }, [filteredItems, viewMode]);

  function handleExpandAll() {
    const next = new Set();
    for (const row of filteredItems) {
      next.add(row.classification_id ?? `idx-${filteredItems.indexOf(row)}`);
    }
    setExpandedRows(next);
  }

  function handleCollapseAll() {
    setExpandedRows(new Set());
  }

  function isRowExpanded(row, index) {
    const rowId = row.classification_id ?? `idx-${index}`;
    return expandedRows.has(rowId);
  }

  useEffect(() => {
    loadItems(false);
  }, []);

  const allExpanded = filteredItems.length > 0 && filteredItems.every((row, i) => isRowExpanded(row, i));

  return (
    <main className="weekly-review-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Weekly Review</h1>
          <span>Actionable queue of items requiring operator attention this week.</span>
        </div>
        <div className="manual-hero-actions">
          <button
            className="icon-button"
            disabled={loading}
            onClick={handleRefresh}
            title="Refresh weekly review items"
            type="button"
          >
            <RefreshCw size={18} aria-hidden="true" />
          </button>
        </div>
      </header>

      {error ? <div className="error-toast">{error}</div> : null}

      <div className="weekly-review-controls">
        <label className="weekly-review-toggle-label">
          <input
            checked={includeNonActionable}
            onChange={handleToggleNonActionable}
            type="checkbox"
          />
          {" "}Show reviewed or snoozed
        </label>
        <div className="weekly-review-view-toggle" role="radiogroup" aria-label="View mode">
          <label>
            <input
              checked={viewMode === "flat"}
              name="weekly-review-view"
              onChange={() => setViewMode("flat")}
              type="radio"
            />
            {" "}Flat list
          </label>
          <label>
            <input
              checked={viewMode === "grouped"}
              name="weekly-review-view"
              onChange={() => setViewMode("grouped")}
              type="radio"
            />
            {" "}Grouped by agreement
          </label>
        </div>
      </div>

      <div className="weekly-review-filter-bar">
        <div className="weekly-review-filter-chips" role="group" aria-label="Filter by verdict">
          {VERDICT_FILTERS.map((f) => {
            const active = verdictFilter === f.code;
            const count = verdictCounts[f.code] ?? 0;
            return (
              <button
                aria-pressed={active}
                className={`weekly-review-chip weekly-review-chip-${f.code.toLowerCase().replaceAll("_", "-")} ${active ? "weekly-review-chip-active" : ""}`}
                key={f.code}
                onClick={() => setVerdictFilter(active ? null : f.code)}
                type="button"
              >
                {f.label} <span className="weekly-review-chip-count">({count})</span>
              </button>
            );
          })}
          {includeNonActionable && snoozedCount > 0 ? (
            <button
              aria-pressed={showSnoozedOnly}
              className={`weekly-review-chip weekly-review-chip-snoozed ${showSnoozedOnly ? "weekly-review-chip-active" : ""}`}
              onClick={() => setShowSnoozedOnly((v) => !v)}
              title="Show snoozed items only — each row has an Un-snooze button"
              type="button"
            >
              Snoozed <span className="weekly-review-chip-count">({snoozedCount})</span>
            </button>
          ) : null}
          {(verdictFilter || showSnoozedOnly) ? (
            <button
              className="weekly-review-clear-filter"
              onClick={() => { setVerdictFilter(null); setShowSnoozedOnly(false); }}
              type="button"
            >
              Clear filters
            </button>
          ) : null}
        </div>
        <div className="weekly-review-expand-controls">
          <button
            className="weekly-review-expand-toggle"
            onClick={allExpanded ? handleCollapseAll : handleExpandAll}
            type="button"
          >
            {allExpanded ? "Collapse all" : "Expand all"}
          </button>
        </div>
      </div>

      {loading ? (
        <EmptyState label="Loading weekly review" hint="Fetching items requiring attention." />
      ) : viewMode === "grouped" ? (
        <div className="weekly-review-groups">
          {groupedItems && groupedItems.length ? (
            groupedItems.map((group) => {
              const expanded = !!expandedGroups[group.key];
              return (
                <section
                  className="weekly-review-group-section"
                  key={group.key}
                >
                  <button
                    aria-expanded={expanded}
                    className="weekly-review-group-header"
                    onClick={() => toggleGroup(group.key)}
                    type="button"
                  >
                    <span className="weekly-review-group-name">
                      {expanded ? "\u25BC" : "\u25B6"} {group.key}
                    </span>
                    <span className="weekly-review-group-row-count">
                      {group.rows.length} item{group.rows.length === 1 ? "" : "s"}
                      {group.breachCount > 0
                        ? ` \u00B7 ${group.breachCount} breach${group.breachCount === 1 ? "" : "es"}`
                        : ""}
                    </span>
                  </button>
                  {expanded ? (
                    <div className="table-wrap weekly-review-group-body">
                      <table className="weekly-review-table">
                        <TableHead
                          onSort={handleSort}
                          sortColumn={sortColumn}
                          sortDirection={sortDirection}
                        />
                        <tbody>
                          {group.rows.map((row, index) => (
                            <WeeklyReviewRow
                              expanded={isRowExpanded(row, index)}
                              index={index}
                              key={row.classification_id ?? `${group.key}-${index}`}
                              onMarkReviewed={markReviewed}
                              onUnreview={unreviewItem}
                              onSnooze={snoozeItem}
                              onUnsnooze={unsnoozeItem}
                              onToggleExpanded={toggleRowExpanded}
                              row={row}
                              today={today}
                            />
                          ))}
                        </tbody>
                      </table>
                    </div>
                  ) : null}
                </section>
              );
            })
          ) : (
            <EmptyState label="Queue is empty" hint="No items require attention this week." />
          )}
        </div>
      ) : (
        <div className="table-wrap">
          <table className="weekly-review-table">
            <TableHead
              onSort={handleSort}
              sortColumn={sortColumn}
              sortDirection={sortDirection}
            />
            <tbody>
              {filteredItems.length ? (
                filteredItems.map((row, index) => (
                  <WeeklyReviewRow
                    expanded={isRowExpanded(row, index)}
                    index={index}
                    key={row.classification_id ?? index}
                    onMarkReviewed={markReviewed}
                    onUnreview={unreviewItem}
                    onSnooze={snoozeItem}
                    onUnsnooze={unsnoozeItem}
                    onToggleExpanded={toggleRowExpanded}
                    row={row}
                    today={today}
                  />
                ))
              ) : (
                <EmptyRow
                  colSpan={7}
                  hint="No items require attention this week."
                  label="Queue is empty"
                />
              )}
            </tbody>
          </table>
        </div>
      )}
    </main>
  );
}
