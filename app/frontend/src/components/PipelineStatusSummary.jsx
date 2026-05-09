import { RefreshCw } from "lucide-react";

function formatRelativeTime(value) {
  if (!value) return "";
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours} hours ago`;
  const days = Math.round(hours / 24);
  return `${days} days ago`;
}

function stepCount(run) {
  const summary = run?.summary ?? {};
  return Number(summary.total_steps_completed ?? 0) + Number(summary.total_steps_failed ?? 0);
}

export function pipelineRunSummary(run) {
  if (!run) return "Pipeline: No runs yet";
  const parts = [
    `Pipeline: ${run.status ?? "unknown"}`,
    formatRelativeTime(run.started_at),
    `${stepCount(run)} steps`,
    `${Number(run.summary?.total_rows_affected ?? 0)} rows`,
  ].filter(Boolean);
  return parts.join(" | ");
}

export default function PipelineStatusSummary({
  latestRun,
  loading = false,
  onRefresh,
  title = "Pipeline",
  emptyLabel = "No runs yet",
  className = "",
}) {
  return (
    <section className={`pipeline-status-summary ${className}`.trim()}>
      <div>
        <p className="pipeline-kicker">{title}</p>
        <strong>{latestRun ? pipelineRunSummary(latestRun) : `Pipeline: ${emptyLabel}`}</strong>
      </div>
      <button className="btn" onClick={onRefresh} type="button">
        <RefreshCw size={16} aria-hidden="true" />
        Refresh
      </button>
      {loading ? <span className="pipeline-muted">Loading...</span> : null}
    </section>
  );
}
