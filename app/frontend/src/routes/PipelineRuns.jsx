import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";

import PipelineRefreshDialog from "../components/PipelineRefreshDialog.jsx";
import PipelineStatusSummary from "../components/PipelineStatusSummary.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const pipelineRunsEndpoint = `${apiBase}/profit/admin/audit/pipeline-runs`;
const PIPELINE_STEP_LABELS = {
  anchor_agreement_sync: "Anchor Agreement Sync",
  anchor_invoice_revenue_sync: "Anchor Invoice and Revenue Sync",
  qbo_collection_loader: "QBO Collection Loader",
  fc_completion_sync: "Financial Cents Completion Sync",
  recognition_trigger_apply: "Recognition Trigger Apply",
  fc_anchor_match_refresh: "FC Anchor Match Refresh",
  fulfillment_audit_refresh: "Fulfillment Audit Refresh",
  classification_transition_apply: "Classification Transition Apply",
};

function formatDateTime(value) {
  if (!value) return "—";
  return new Date(value).toLocaleString("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function durationLabel(seconds) {
  if (seconds === null || seconds === undefined) return "—";
  if (Number(seconds) < 60) return `${seconds}s`;
  return `${Math.floor(Number(seconds) / 60)}m ${Number(seconds) % 60}s`;
}

function truncate(value) {
  const text = String(value ?? "");
  return text.length > 200 ? `${text.slice(0, 197)}...` : text;
}

function friendlyStepName(stepName) {
  return PIPELINE_STEP_LABELS[stepName] ?? String(stepName ?? "Unknown step").replaceAll("_", " ");
}

function statusBadge(status) {
  return <span className={`pipeline-status-badge pipeline-status-${status ?? "unknown"}`}>{status ?? "unknown"}</span>;
}

function detailsSummary(details) {
  if (!details) return "—";
  const error = details.error ?? details.error_summary;
  if (error) return truncate(error);
  if (details.sub_workflows?.length) return `${details.sub_workflows.length} sub-workflows`;
  if (details.function_result) return truncate(JSON.stringify(details.function_result));
  return truncate(JSON.stringify(details));
}

function SubWorkflowList({ details }) {
  const subWorkflows = details ? details.sub_workflows ?? [] : [];
  if (!subWorkflows.length) return null;
  return (
    <ul className="pipeline-sub-workflows">
      {subWorkflows.map((item) => (
        <li key={item.name}>
          <strong>{item.name}</strong>
          <span>{item.status}</span>
          <span>{Number(item.rows_affected ?? 0)} rows</span>
          {item.error ? <em>{truncate(item.error)}</em> : null}
        </li>
      ))}
    </ul>
  );
}

function latestStep(run) {
  const steps = run.steps ?? [];
  return steps[steps.length - 1] ?? null;
}

function failedStepName(run) {
  return run.summary?.failed_step_name
    ?? run.steps?.find((step) => step.status === "failed")?.step_name
    ?? latestStep(run)?.step_name;
}

function friendlyRunSummary(run) {
  const summary = run.summary ?? {};
  const completed = Number(summary.total_steps_completed ?? 0);
  const failed = Number(summary.total_steps_failed ?? 0);
  if (run.status === "running") {
    const step = latestStep(run);
    return step
      ? `Running step ${step.step_order} of 8 — ${friendlyStepName(step.step_name)}`
      : "Pipeline is starting";
  }
  if (run.status === "success") {
    return `All 8 steps completed in ${durationLabel(run.duration_seconds)}`;
  }
  if (run.status === "failed") {
    const step = failedStepName(run);
    if (completed === 0 && !(run.steps ?? []).length) {
      return "Pipeline halted before any step ran";
    }
    if (!step) {
      return `${completed} of 8 steps completed; halted before further progress`;
    }
    const stepName = friendlyStepName(step);
    return `${completed} of 8 steps completed; halted at step ${stepName}`;
  }
  if (run.status === "partial") {
    return `8 steps attempted; ${failed} soft step${failed === 1 ? "" : "s"} failed`;
  }
  return `${completed} of 8 steps completed`;
}

function SummaryDetails({ run }) {
  const summary = run.summary ?? {};
  return (
    <details className="pipeline-summary-details">
      <summary>Show details</summary>
      {summary.error_summary ? <p><strong>Error:</strong> {summary.error_summary}</p> : null}
      {summary.notable_findings ? <p><strong>Notes:</strong> {summary.notable_findings}</p> : null}
    </details>
  );
}

function RunSummaryBlock({ run }) {
  const summary = run.summary ?? {};
  return (
    <div className="pipeline-summary-block">
      <dl className="pipeline-run-meta">
        <dt>Steps Completed</dt>
        <dd>{Number(summary.total_steps_completed ?? 0)} of 8</dd>
        <dt>Steps Failed</dt>
        <dd>{Number(summary.total_steps_failed ?? 0)}</dd>
        <dt>Total Rows Affected</dt>
        <dd>{Number(summary.total_rows_affected ?? 0)}</dd>
        <dt>Error Summary</dt>
        <dd>{summary.error_summary ?? "—"}</dd>
        <dt>Notable Findings</dt>
        <dd>{summary.notable_findings ?? "—"}</dd>
      </dl>
      <details className="pipeline-summary-details">
        <summary>Show raw summary</summary>
        <pre>{JSON.stringify(summary, null, 2)}</pre>
      </details>
    </div>
  );
}

export default function PipelineRuns() {
  const { pipelineRunId } = useParams();
  const [runs, setRuns] = useState([]);
  const [detail, setDetail] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [dialogOpen, setDialogOpen] = useState(false);

  const latestRun = useMemo(() => detail?.run ?? runs[0] ?? null, [detail, runs]);

  async function loadRuns() {
    setLoading(true);
    setError("");
    try {
      const response = await fetch(`${pipelineRunsEndpoint}?limit=20&offset=0`);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `Pipeline runs request failed: ${response.status}`);
      const rows = payload.rows ?? [];
      const rowsWithStepContext = await Promise.all(rows.map(async (run) => {
        if (!["running", "failed", "partial"].includes(run.status)) return run;
        const detailResponse = await fetch(`${pipelineRunsEndpoint}/${run.pipeline_run_id}`);
        if (!detailResponse.ok) return run;
        const detailPayload = await detailResponse.json();
        return { ...run, steps: detailPayload.steps ?? [] };
      }));
      setRuns(rowsWithStepContext);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Pipeline runs request failed");
    } finally {
      setLoading(false);
    }
  }

  async function loadRunDetail() {
    if (!pipelineRunId) return;
    setLoading(true);
    setError("");
    try {
      const response = await fetch(`${pipelineRunsEndpoint}/${pipelineRunId}`);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail ?? `Pipeline run request failed: ${response.status}`);
      setDetail(payload);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Pipeline run request failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    if (pipelineRunId) {
      loadRunDetail();
    } else {
      setDetail(null);
      loadRuns();
    }
  }, [pipelineRunId]);

  useEffect(() => {
    if (pipelineRunId && detail?.run?.status === "running") {
      const intervalId = setInterval(loadRunDetail, 4000);
      return () => clearInterval(intervalId);
    }
    return undefined;
  }, [pipelineRunId, detail?.run?.status]);

  return (
    <main className="pipeline-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Pipeline Runs</h1>
          <span>Manual orchestration history for fulfillment pipeline refreshes.</span>
        </div>
        <button className="btn btn-primary" onClick={() => setDialogOpen(true)} type="button">
          Refresh
        </button>
      </header>

      <PipelineStatusSummary
        latestRun={latestRun}
        loading={loading}
        onRefresh={() => setDialogOpen(true)}
        emptyLabel="No runs yet"
      />
      {error ? <div className="error-toast">{error}</div> : null}

      {pipelineRunId ? (
        <section className="panel pipeline-detail-panel">
          <div className="panel-title">
            <h2>Run detail</h2>
            {detail?.run ? statusBadge(detail.run.status) : null}
          </div>
          {detail?.run ? (
            <>
              <dl className="pipeline-run-meta">
                <dt>Run ID</dt>
                <dd>{detail.run.pipeline_run_id}</dd>
                <dt>Started</dt>
                <dd>{formatDateTime(detail.run.started_at)}</dd>
                <dt>Finished</dt>
                <dd>{formatDateTime(detail.run.finished_at)}</dd>
                <dt>Duration</dt>
                <dd>{durationLabel(detail.run.duration_seconds)}</dd>
                <dt>Summary</dt>
                <dd>{friendlyRunSummary({ ...detail.run, steps: detail.steps ?? [] })}</dd>
              </dl>
              <RunSummaryBlock run={detail.run} />
            </>
          ) : null}
          <div className="table-wrap">
            <table className="pipeline-table">
              <thead>
                <tr>
                  <th>Order</th>
                  <th>Step</th>
                  <th>Status</th>
                  <th>Duration</th>
                  <th>Rows</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                {(detail?.steps ?? []).map((step) => (
                  <tr key={step.step_name}>
                    <td>{step.step_order}</td>
                    <td>{friendlyStepName(step.step_name)}</td>
                    <td>{statusBadge(step.status)}</td>
                    <td>{durationLabel(step.duration_seconds)}</td>
                    <td>{Number(step.rows_affected ?? 0)}</td>
                    <td>
                      <span>{detailsSummary(step.details)}</span>
                      <SubWorkflowList details={step.details} />
                    </td>
                  </tr>
                ))}
                {detail?.steps?.length ? null : (
                  <tr>
                    <td className="empty" colSpan={6}>No step rows recorded for this run yet</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>
      ) : (
        <section className="panel pipeline-list-panel">
          <div className="panel-title">
            <h2>Run log</h2>
          </div>
          <div className="table-wrap">
            <table className="pipeline-table">
              <thead>
                <tr>
                  <th>Started</th>
                  <th>Source</th>
                  <th>Triggered by</th>
                  <th>Status</th>
                  <th>Duration</th>
                  <th>Rows</th>
                  <th>Summary</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                {runs.map((run) => (
                  <tr key={run.pipeline_run_id}>
                    <td>{formatDateTime(run.started_at)}</td>
                    <td>{run.run_source}</td>
                    <td>{run.triggered_by ?? "—"}</td>
                    <td>{statusBadge(run.status)}</td>
                    <td>{durationLabel(run.duration_seconds)}</td>
                    <td>{Number(run.summary?.total_rows_affected ?? 0)}</td>
                    <td>
                      <span>{friendlyRunSummary(run)}</span>
                      <SummaryDetails run={run} />
                    </td>
                    <td><Link to={`/admin/pipeline/${run.pipeline_run_id}`}>View details</Link></td>
                  </tr>
                ))}
                {runs.length ? null : (
                  <tr>
                    <td className="empty" colSpan={8}>No pipeline runs to show. Trigger a manual refresh to start.</td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <PipelineRefreshDialog
        open={dialogOpen}
        onClose={() => setDialogOpen(false)}
        onSubmitted={(run) => setDetail((current) => (current ? { ...current, run } : current))}
      />
    </main>
  );
}
