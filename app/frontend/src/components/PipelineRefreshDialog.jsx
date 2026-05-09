import { useState } from "react";
import { useNavigate } from "react-router-dom";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const pipelineRunsEndpoint = `${apiBase}/profit/admin/audit/pipeline-runs`;

function errorMessage(response, payload) {
  if (response.status === 409) {
    return payload?.detail?.message ?? "Pipeline already running. Refresh again when complete.";
  }
  return payload?.detail?.message ?? `Pipeline refresh failed: ${response.status}`;
}

export default function PipelineRefreshDialog({ open, onClose, onSubmitted }) {
  const [triggeredBy, setTriggeredBy] = useState("orlando");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const navigate = useNavigate();

  if (!open) return null;

  async function submitRefresh(event) {
    event.preventDefault();
    setSubmitting(true);
    setError("");
    try {
      const response = await fetch(pipelineRunsEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ triggered_by: triggeredBy || "orlando" }),
      });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(errorMessage(response, payload));
      }
      const runId = payload.run?.pipeline_run_id;
      onSubmitted?.(payload.run);
      onClose?.();
      if (runId) navigate(`/admin/pipeline/${runId}`);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Pipeline refresh failed");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="pipeline-dialog-backdrop" role="presentation">
      <form className="pipeline-refresh-dialog" onSubmit={submitRefresh}>
        <div className="pipeline-dialog-header">
          <div>
            <p className="pipeline-kicker">Manual refresh</p>
            <h2>Run fulfillment pipeline</h2>
          </div>
          <button aria-label="Close" className="icon-button" onClick={onClose} type="button">×</button>
        </div>
        <label className="pipeline-field">
          <span>triggered_by</span>
          <input
            value={triggeredBy}
            onChange={(event) => setTriggeredBy(event.target.value)}
            placeholder="orlando"
          />
        </label>
        {error ? <div className="error-toast">{error}</div> : null}
        <div className="pipeline-dialog-actions">
          <button className="btn" onClick={onClose} type="button">Cancel</button>
          <button className="btn btn-primary" disabled={submitting} type="submit">
            {submitting ? "Pipeline running..." : "Confirm refresh"}
          </button>
        </div>
      </form>
    </div>
  );
}
