import { useEffect, useMemo, useState } from "react";
import { RefreshCw } from "lucide-react";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const itemsEndpoint = `${apiBase}/profit/admin/weekly-review/items`;

const ITEM_TYPE_LABELS = {
  MANUAL_INVOICE_PENDING: "Manual Invoice Pending",
  SLA_BREACHED: "SLA Breached",
};

const SORT_KEYS = {
  rank: "rank",
  client_name: "client_name",
  service_name: "service_name",
  verdict_code: "verdict_code",
};

function itemTypeBadge(itemType) {
  const normalized = String(itemType ?? "unknown");
  const label = ITEM_TYPE_LABELS[normalized] ?? normalized.replaceAll("_", " ");
  return <span className="weekly-review-badge">{label}</span>;
}

function attributionBadge(row) {
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
    </div>
  );
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

function WeeklyReviewRow({ row, index, onMarkReviewed, onSnooze }) {
  const badge = attributionBadge(row);
  return (
    <tr key={row.classification_id ?? index}>
      <td>{row.sort_rank ?? index + 1}</td>
      <td>
        <span className="weekly-review-primary">{textValue(row.client_name, row.anchor_client_business_name)}</span>
      </td>
      <td>{textValue(row.service_name, row.services)}</td>
      <td>
        <div className="weekly-review-type-cell">
          {itemTypeBadge(row.item_type ?? row.verdict_code ?? "MANUAL_INVOICE_PENDING")}
          {badge}
        </div>
      </td>
      <td>
        {row.verdict_code === "SLA_BREACHED" ? (
          <SlaDetails row={row} />
        ) : (
          <ManualInvoiceDetails row={row} />
        )}
      </td>
      <td>
        {row.action_url ? (
          <a
            className="weekly-review-action-link"
            href={row.action_url}
            rel="noopener noreferrer"
            target="_blank"
          >
            Open work item
          </a>
        ) : (
          "-"
        )}
      </td>
      <td className="weekly-review-controls-cell">
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
  const [includeReviewed, setIncludeReviewed] = useState(false);
  const [sortColumn, setSortColumn] = useState("rank");
  const [sortDirection, setSortDirection] = useState("asc");
  const [viewMode, setViewMode] = useState("flat");
  const [expandedGroups, setExpandedGroups] = useState({});

  async function loadItems(withReviewed) {
    setLoading(true);
    setError("");
    try {
      const url = withReviewed
        ? `${itemsEndpoint}?include_reviewed=true`
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
    loadItems(includeReviewed);
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
    loadItems(includeReviewed);
  }

  function handleToggleReviewed() {
    const next = !includeReviewed;
    setIncludeReviewed(next);
    loadItems(next);
  }

  function handleRefresh() {
    loadItems(includeReviewed);
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

  const sortedItems = useMemo(() => {
    const arr = Array.isArray(items) ? items.slice() : [];
    arr.sort((a, b) => compareRows(a, b, sortColumn, sortDirection));
    return arr;
  }, [items, sortColumn, sortDirection]);

  const groupedItems = useMemo(() => {
    if (viewMode !== "grouped") return null;
    const groups = new Map();
    for (const row of sortedItems) {
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
  }, [sortedItems, viewMode]);

  useEffect(() => {
    loadItems(false);
  }, []);

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
            checked={includeReviewed}
            onChange={handleToggleReviewed}
            type="checkbox"
          />
          {" "}Show reviewed
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
                        ? ` · ${group.breachCount} breach${group.breachCount === 1 ? "" : "es"}`
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
                              index={index}
                              key={row.classification_id ?? `${group.key}-${index}`}
                              onMarkReviewed={markReviewed}
                              onSnooze={snoozeItem}
                              row={row}
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
              {sortedItems.length ? (
                sortedItems.map((row, index) => (
                  <WeeklyReviewRow
                    index={index}
                    key={row.classification_id ?? index}
                    onMarkReviewed={markReviewed}
                    onSnooze={snoozeItem}
                    row={row}
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
