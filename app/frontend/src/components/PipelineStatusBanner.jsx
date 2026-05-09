import { AlertOctagon, AlertTriangle, RefreshCw } from "lucide-react";
import { Link } from "react-router-dom";

function relativeTime(value) {
  if (!value) return "";
  const seconds = Math.max(0, Math.round((Date.now() - new Date(value).getTime()) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  return `${days}d ago`;
}

const STATUS_TEXT = {
  failed: {
    title: "Pipeline run failed",
    body: "Recognized revenue and downstream GP tiles may be stale or empty until the next successful run.",
  },
  partial: {
    title: "Pipeline finished with errors",
    body: "Some pipeline steps failed. Affected tiles may show partial or stale data.",
  },
};

export default function PipelineStatusBanner({ latestRun, onRerun }) {
  if (!latestRun) return null;
  const status = latestRun.status;
  if (status !== "failed" && status !== "partial") return null;

  const text = STATUS_TEXT[status];
  const isFailed = status === "failed";
  const Icon = isFailed ? AlertOctagon : AlertTriangle;
  const errorSummary = latestRun.summary?.error_summary;
  const stepsCompleted = Number(latestRun.summary?.total_steps_completed ?? 0);
  const stepsFailed = Number(latestRun.summary?.total_steps_failed ?? 0);

  return (
    <div className={`pipeline-banner pipeline-banner-${isFailed ? "error" : "warn"}`} role="alert">
      <div className="pipeline-banner-icon" aria-hidden="true">
        <Icon size={20} />
      </div>
      <div className="pipeline-banner-body">
        <p className="pipeline-banner-title">
          <strong>{text.title}</strong>
          <span className="pipeline-banner-time"> · {relativeTime(latestRun.started_at)}</span>
          {stepsCompleted + stepsFailed > 0 ? (
            <span className="pipeline-banner-time">
              {" "}· {stepsCompleted}/{stepsCompleted + stepsFailed} steps
            </span>
          ) : null}
        </p>
        <p className="pipeline-banner-detail">
          {errorSummary ? <span className="pipeline-banner-errcode">{errorSummary}</span> : null}
          <span>{text.body}</span>
        </p>
      </div>
      <div className="pipeline-banner-actions">
        <Link
          className="pipeline-banner-link"
          to={`/admin/pipeline/${latestRun.pipeline_run_id}`}
        >
          View run details
        </Link>
        {onRerun ? (
          <button className="pipeline-banner-button" onClick={onRerun} type="button">
            <RefreshCw aria-hidden="true" size={14} />
            Run pipeline now
          </button>
        ) : null}
      </div>
    </div>
  );
}
