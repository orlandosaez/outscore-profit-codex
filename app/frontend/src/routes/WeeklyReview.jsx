import { useEffect, useState } from "react";
import { RefreshCw } from "lucide-react";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const itemsEndpoint = `${apiBase}/profit/admin/weekly-review/items`;

const ITEM_TYPE_LABELS = {
  MANUAL_INVOICE_PENDING: "Manual Invoice Pending",
};

function itemTypeBadge(itemType) {
  const normalized = String(itemType ?? "unknown");
  const label = ITEM_TYPE_LABELS[normalized] ?? normalized.replaceAll("_", " ");
  return <span className="weekly-review-badge">{label}</span>;
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

export default function WeeklyReview() {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [includeReviewed, setIncludeReviewed] = useState(false);

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
      </div>

      {loading ? (
        <EmptyState label="Loading weekly review" hint="Fetching items requiring attention." />
      ) : (
        <div className="table-wrap">
          <table className="weekly-review-table">
            <thead>
              <tr>
                <th>Rank</th>
                <th>Age (days)</th>
                <th>Client</th>
                <th>Services</th>
                <th>Invoice State</th>
                <th>Est. Annual Rev</th>
                <th>Action</th>
                <th>Controls</th>
              </tr>
            </thead>
            <tbody>
              {items.length ? (
                items.map((row, index) => (
                  <tr key={row.classification_id ?? index}>
                    <td>{index + 1}</td>
                    <td>{textValue(row.age_days)}</td>
                    <td>
                      <span className="weekly-review-primary">{textValue(row.client_name, row.anchor_client_business_name)}</span>
                    </td>
                    <td>{textValue(row.service_name, row.services)}</td>
                    <td>{itemTypeBadge(row.item_type ?? "MANUAL_INVOICE_PENDING")}</td>
                    <td>{currencyValue(row.est_annual_revenue ?? row.estimated_annual_revenue)}</td>
                    <td>
                      {row.action_url ? (
                        <a
                          className="weekly-review-action-link"
                          href={row.action_url}
                          rel="noopener noreferrer"
                          target="_blank"
                        >
                          Open in Anchor
                        </a>
                      ) : (
                        "-"
                      )}
                    </td>
                    <td className="weekly-review-controls-cell">
                      <button
                        className="btn btn-secondary btn-sm"
                        onClick={() => markReviewed(row.classification_id)}
                        title="Mark this item as reviewed"
                        type="button"
                      >
                        Mark reviewed
                      </button>
                      <button
                        className="btn btn-secondary btn-sm"
                        onClick={() => snoozeItem(row.classification_id)}
                        title="Snooze this item for 7 days"
                        type="button"
                      >
                        Snooze 7 days
                      </button>
                    </td>
                  </tr>
                ))
              ) : (
                <EmptyRow
                  colSpan={8}
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
