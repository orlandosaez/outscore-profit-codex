import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { AlertOctagon, AlertTriangle, CheckCircle2, ShieldAlert } from "lucide-react";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const summaryEndpoint = `${apiBase}/profit/admin/data-quality-alerts/summary`;

/**
 * V0.7.E.0.1 T3 — top-of-dashboard self-audit chip.
 * Reads profit_data_quality_alerts summary and surfaces high-severity count.
 * Click-through to /admin/data-quality for triage.
 */
export default function DataQualityChip() {
  const [summary, setSummary] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    async function load() {
      try {
        const response = await fetch(summaryEndpoint);
        if (!response.ok) throw new Error(`summary ${response.status}`);
        const payload = await response.json();
        if (!cancelled) setSummary(payload);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : "load failed");
      }
    }
    load();
    return () => {
      cancelled = true;
    };
  }, []);

  if (error) {
    return (
      <div className="pipeline-banner pipeline-banner-warn" role="status">
        <div className="pipeline-banner-icon" aria-hidden="true">
          <ShieldAlert size={20} />
        </div>
        <div className="pipeline-banner-body">
          <p className="pipeline-banner-title">
            <strong>Self-audit: status unavailable</strong>
          </p>
          <p className="pipeline-banner-detail">
            <span>{error}</span>
          </p>
        </div>
        <div className="pipeline-banner-actions">
          <Link className="pipeline-banner-link" to="/admin/data-quality">
            View details
          </Link>
        </div>
      </div>
    );
  }

  if (!summary) return null; // quiet while loading

  const high = summary.by_severity?.high ?? 0;
  const medium = summary.by_severity?.medium ?? 0;
  const status = summary.audit_status ?? "clean";

  const variant =
    status === "critical" ? "error" : status === "alerts" ? "warn" : "good";
  const Icon =
    status === "critical"
      ? AlertOctagon
      : status === "alerts"
      ? AlertTriangle
      : CheckCircle2;

  const title =
    status === "critical"
      ? "Self-audit: critical findings"
      : status === "alerts"
      ? "Self-audit: alerts"
      : "Self-audit: clean";

  const detail =
    status === "critical"
      ? `${high} high-severity finding${high === 1 ? "" : "s"}${
          medium ? ` + ${medium} medium-severity` : ""
        } across Anchor + FC + QBO consistency checks.`
      : status === "alerts"
      ? `${medium} medium-severity finding${medium === 1 ? "" : "s"} — no high-severity items.`
      : "All 11 cross-source consistency checks passed on the most recent pipeline run.";

  return (
    <div className={`pipeline-banner pipeline-banner-${variant}`} role="status">
      <div className="pipeline-banner-icon" aria-hidden="true">
        <Icon size={20} />
      </div>
      <div className="pipeline-banner-body">
        <p className="pipeline-banner-title">
          <strong>{title}</strong>
          <span className="pipeline-banner-time"> · total {summary.total ?? 0}</span>
        </p>
        <p className="pipeline-banner-detail">
          <span>{detail}</span>
        </p>
      </div>
      <div className="pipeline-banner-actions">
        <Link className="pipeline-banner-link" to="/admin/data-quality">
          View details
        </Link>
      </div>
    </div>
  );
}
