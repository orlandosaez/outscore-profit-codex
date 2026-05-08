import { useEffect, useMemo, useState } from "react";
import { CheckSquare, RefreshCw, Search } from "lucide-react";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const candidatesEndpoint = `${apiBase}/profit/admin/audit/candidates`;
const verdictsEndpoint = `${apiBase}/profit/admin/audit/verdicts`;
const filterOptionsEndpoint = `${apiBase}/profit/admin/audit/filter-options`;
const classificationsEndpoint = `${apiBase}/profit/admin/audit/classifications`;
const qboCategoryGapsEndpoint = `${apiBase}/profit/admin/audit/qbo-category-gaps`;
const UNCLASSIFIED_VERDICT = "__UNCLASSIFIED__";

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function formatMoney(value, { dashZero = false } = {}) {
  const numeric = Number(value ?? 0);
  if ((value === null || value === undefined) || (dashZero && numeric === 0)) return "—";
  return money.format(numeric);
}

function formatDate(value) {
  if (!value) return "—";
  return new Date(`${String(value).slice(0, 10)}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function verdictLabel(row, verdictMap) {
  if (!row.current_verdict_code) {
    return <span className="audit-verdict-muted">Unclassified</span>;
  }
  const verdict = verdictMap.get(row.current_verdict_code);
  if (!verdict) {
    return (
      <span className="audit-verdict-unknown">
        {row.current_verdict_code}
        <small>Unknown verdict</small>
      </span>
    );
  }
  return (
    <span className={`audit-verdict-badge audit-verdict-${verdict.category}`}>
      {verdict.label ?? row.current_verdict_code}
    </span>
  );
}

function statusBadge(status) {
  return <span className={`audit-status audit-status-${status ?? "none"}`}>{status ?? "—"}</span>;
}

function tagList(tags) {
  if (!tags?.length) return <span className="audit-muted">—</span>;
  return (
    <span className="audit-chip-list">
      {tags.map((tag) => <span className="audit-chip" key={tag}>{tag}</span>)}
    </span>
  );
}

function detailEndpoint(fcClientId) {
  return `${candidatesEndpoint}/${fcClientId}`;
}

function parseApiError(response, body) {
  const detail = body?.detail;
  if (response.status === 422 && detail?.row_index !== undefined) {
    return {
      status: response.status,
      message: detail.message ?? "Validation failed",
      field: detail.field,
      row_index: detail.row_index,
      fc_client_id: detail.fc_client_id,
      current_classification_id: detail.current_classification_id,
      current_verdict_code: detail.current_verdict_code,
      kind: "validation",
    };
  }
  if (response.status === 422) {
    return {
      status: response.status,
      message: detail?.message ?? "Validation failed",
      field: detail?.field,
      kind: "validation",
    };
  }
  if (response.status === 409) {
    return {
      status: response.status,
      message: detail?.message ?? "Row updated since you loaded it. Refresh and retry.",
      field: detail?.field,
      row_index: detail?.row_index,
      fc_client_id: detail?.fc_client_id,
      current_classification_id: detail?.current_classification_id,
      current_verdict_code: detail?.current_verdict_code,
      kind: "conflict",
    };
  }
  return {
    status: response.status,
    message: `Request failed (${response.status}): ${JSON.stringify(body)}`,
    kind: "unknown",
  };
}

function stripRequestPrefix(notes) {
  return String(notes ?? "").replace(/^\[req:[^\]]+\]\s*/, "");
}

function fieldValue(value, formatter = (input) => input) {
  if (value === null || value === undefined || value === "") return <span className="audit-muted">—</span>;
  return formatter(value);
}

function transitionBadge(rule) {
  if (rule.signal_present && rule.auto_apply_enabled_in_b2a) {
    return <span className="audit-transition-badge audit-transition-auto">Will auto-apply on next pipeline run</span>;
  }
  if (rule.signal_present) {
    return <span className="audit-transition-badge audit-transition-manual">Eligible — manual apply only (V0.6.C will automate)</span>;
  }
  return <span className="audit-transition-badge audit-transition-muted">Not eligible: {rule.signal_reason}</span>;
}

export default function AuditDashboard() {
  const [rows, setRows] = useState([]);
  const [verdicts, setVerdicts] = useState([]);
  const [filterOptions, setFilterOptions] = useState({
    verdicts: [],
    staff: [],
    service_tags: [],
    groups: [],
  });
  const [showAll, setShowAll] = useState(false);
  const [verdictFilter, setVerdictFilter] = useState("");
  const [groupFilter, setGroupFilter] = useState("");
  const [serviceTagFilter, setServiceTagFilter] = useState("");
  const [staffFilter, setStaffFilter] = useState("");
  const [reEvaluationDue, setReEvaluationDue] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedRows, setSelectedRows] = useState({});
  const [bulkVerdictCode, setBulkVerdictCode] = useState("");
  const [bulkNotes, setBulkNotes] = useState("");
  const [bulkReEvaluateAt, setBulkReEvaluateAt] = useState("");
  const [bulkRequestId, setBulkRequestId] = useState("");
  const [bulkRowError, setBulkRowError] = useState(null);
  const [activeDetailClientId, setActiveDetailClientId] = useState(null);
  const [detailPayload, setDetailPayload] = useState(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState("");
  const [qboCategoryGaps, setQboCategoryGaps] = useState([]);
  const [diagnosticsOpen, setDiagnosticsOpen] = useState(false);
  const [diagnosticsLoading, setDiagnosticsLoading] = useState(false);
  const [diagnosticsError, setDiagnosticsError] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [toast, setToast] = useState("");

  const verdictMap = useMemo(
    () => new Map(verdicts.map((verdict) => [verdict.verdict_code, verdict])),
    [verdicts],
  );

  const groupedQboCategoryGaps = useMemo(
    () => qboCategoryGaps.reduce((groups, row) => {
      const origin = row.gap_origin ?? "unknown";
      return { ...groups, [origin]: [...(groups[origin] ?? []), row] };
    }, {}),
    [qboCategoryGaps],
  );

  async function loadVerdicts() {
    const response = await fetch(verdictsEndpoint);
    if (!response.ok) throw new Error(`Verdicts request failed: ${response.status}`);
    const payload = await response.json();
    setVerdicts(payload.rows ?? []);
  }

  async function loadFilterOptions() {
    const response = await fetch(filterOptionsEndpoint);
    if (!response.ok) throw new Error(`Filter options request failed: ${response.status}`);
    const payload = await response.json();
    setFilterOptions({
      verdicts: payload.verdicts ?? [],
      staff: payload.staff ?? [],
      service_tags: payload.service_tags ?? [],
      groups: payload.groups ?? [],
    });
  }

  async function loadCandidates() {
    const params = new URLSearchParams();
    params.set("show_all", showAll ? "true" : "false");
    params.set("limit", "200");
    if (verdictFilter) params.set("verdict_code", verdictFilter);
    if (groupFilter) params.set("group", groupFilter);
    if (serviceTagFilter) params.set("service_tag", serviceTagFilter);
    if (staffFilter) params.set("staff", staffFilter);
    if (reEvaluationDue) params.set("re_evaluation_due", "true");
    if (search.trim()) params.set("search", search.trim());

    const response = await fetch(`${candidatesEndpoint}?${params.toString()}`);
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.detail?.message ?? `Candidates request failed: ${response.status}`);
    setRows(payload.rows ?? []);
  }

  async function loadCandidateDetail(row) {
    setActiveDetailClientId(row.fc_client_id);
    setDetailLoading(true);
    setDetailError("");
    try {
      const response = await fetch(detailEndpoint(row.fc_client_id));
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail ?? `Detail request failed: ${response.status}`);
      setDetailPayload(payload);
    } catch (err) {
      setDetailError(err instanceof Error ? err.message : "Detail request failed");
      setDetailPayload(null);
    } finally {
      setDetailLoading(false);
    }
  }

  async function loadQboCategoryGaps() {
    setDiagnosticsOpen(true);
    setDiagnosticsLoading(true);
    setDiagnosticsError("");
    try {
      const response = await fetch(qboCategoryGapsEndpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `QBO category gaps request failed: ${response.status}`);
      setQboCategoryGaps(payload.rows ?? []);
    } catch (err) {
      setDiagnosticsError(err instanceof Error ? err.message : "QBO diagnostics request failed");
    } finally {
      setDiagnosticsLoading(false);
    }
  }

  async function refreshPage() {
    setLoading(true);
    setError("");
    try {
      await Promise.all([loadVerdicts(), loadFilterOptions(), loadCandidates()]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Audit dashboard refresh failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    refreshPage();
  }, []);

  function applyFilters() {
    refreshPage();
  }

  function handleFilterKeyDown(event) {
    if (event.key === "Enter") {
      event.preventDefault();
      applyFilters();
    }
  }

  function toggleRow(row, checked) {
    setSelectedRows((current) => {
      const next = { ...current };
      if (checked) {
        next[row.fc_client_id] = {
          fc_client_id: row.fc_client_id,
          classification_id_to_supersede: row.current_classification_id ?? null,
        };
      } else {
        delete next[row.fc_client_id];
      }
      return next;
    });
  }

  const selectedCount = Object.keys(selectedRows).length;
  const selectedVerdict = verdictMap.get(bulkVerdictCode);
  const requiresNotes = selectedVerdict
    ? ["mixed", "leak", "manual_review"].includes(selectedVerdict.category)
    : false;
  const bulkApplyDisabled = loading
    || selectedCount === 0
    || !bulkVerdictCode
    || (requiresNotes && !bulkNotes.trim());

  function openBulkPanel() {
    setBulkRequestId((current) => current || crypto.randomUUID());
    setBulkRowError(null);
  }

  async function applyBulkClassification() {
    if (bulkApplyDisabled) return;
    const requestId = bulkRequestId || crypto.randomUUID();
    setBulkRequestId(requestId);
    setLoading(true);
    setError("");
    setBulkRowError(null);
    try {
      const response = await fetch(classificationsEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          request_id: requestId,
          classified_by: "orlando",
          rows: Object.values(selectedRows).map((row) => ({
            fc_client_id: row.fc_client_id,
            classification_id_to_supersede: row.classification_id_to_supersede,
            new_verdict_code: bulkVerdictCode,
            re_evaluate_at: bulkReEvaluateAt || null,
            notes: bulkNotes,
          })),
        }),
      });
      const payload = await response.json();
      if (!response.ok) {
        const parsed = parseApiError(response, payload);
        if (parsed.kind === "validation") setBulkRowError(parsed);
        if (parsed.kind === "conflict") {
          setBulkRowError(parsed);
          setError(`${parsed.message} Refresh`);
        } else {
          setError(parsed.message);
        }
        return;
      }
      setToast(`Applied ${payload.applied_count} classification${payload.applied_count === 1 ? "" : "s"}`);
      setSelectedRows({});
      setBulkVerdictCode("");
      setBulkNotes("");
      setBulkReEvaluateAt("");
      setBulkRequestId("");
      await loadCandidates();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Bulk classification failed");
    } finally {
      setLoading(false);
    }
  }

  return (
    <main className="audit-dashboard-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Fulfillment Audit</h1>
          <span>Classify fulfillment audit candidates from the live V0.6 data foundation.</span>
        </div>
        <div className="manual-hero-actions">
          <button className="btn" onClick={loadQboCategoryGaps} disabled={diagnosticsLoading} type="button">
            QBO gaps
          </button>
          <button className="icon-button" onClick={refreshPage} disabled={loading} title="Refresh audit data" type="button">
            <RefreshCw size={18} aria-hidden="true" />
          </button>
        </div>
      </header>

      {toast ? <div className="success-toast"><CheckSquare size={16} aria-hidden="true" />{toast}</div> : null}
      {error ? <div className="error-toast">{error}</div> : null}

      <section className="panel audit-filter-panel">
        <div className="panel-title">
          <Search size={18} aria-hidden="true" />
          <h2>Audit queue</h2>
          <span>Showing {rows.length} rows</span>
        </div>
        <div className="audit-filters">
          <input value={search} onChange={(event) => setSearch(event.target.value)} onKeyDown={handleFilterKeyDown} placeholder="Search client" />
          <select value={verdictFilter} onChange={(event) => setVerdictFilter(event.target.value)}>
            <option value="">All</option>
            <option value={UNCLASSIFIED_VERDICT}>Unclassified</option>
            {verdicts.map((verdict) => (
              <option value={verdict.verdict_code} key={verdict.verdict_code}>{verdict.label}</option>
            ))}
          </select>
          <select value={groupFilter} onChange={(event) => setGroupFilter(event.target.value)}>
            <option value="">All groups</option>
            {filterOptions.groups.map((group) => (
              <option value={group} key={group}>{group}</option>
            ))}
          </select>
          <select value={serviceTagFilter} onChange={(event) => setServiceTagFilter(event.target.value)}>
            <option value="">All services</option>
            {filterOptions.service_tags.map((tag) => (
              <option value={tag} key={tag}>{tag}</option>
            ))}
          </select>
          {filterOptions.staff.length > 0 ? (
            <select value={staffFilter} onChange={(event) => setStaffFilter(event.target.value)}>
              <option value="">All staff</option>
              {filterOptions.staff.map((staff) => (
                <option value={staff} key={staff}>{staff}</option>
              ))}
            </select>
          ) : null}
          <button onClick={applyFilters} disabled={loading} type="button">Apply filters</button>
        </div>
        <div className="audit-filter-options">
          <label className="inline-toggle">
            <input checked={showAll} onChange={(event) => setShowAll(event.target.checked)} type="checkbox" />
            Show all
          </label>
          <label className="inline-toggle">
            <input checked={reEvaluationDue} onChange={(event) => setReEvaluationDue(event.target.checked)} type="checkbox" />
            Re-evaluation due
          </label>
          <span>{selectedCount} selected</span>
        </div>
      </section>

      <section className="panel">
        <div className="audit-bulk-panel">
          <div>
            <h2>Bulk classify</h2>
            <span>{selectedCount} selected</span>
          </div>
          <select
            value={bulkVerdictCode}
            onChange={(event) => {
              setBulkVerdictCode(event.target.value);
              openBulkPanel();
            }}
          >
            <option value="">Select verdict...</option>
            {verdicts.map((verdict) => (
              <option value={verdict.verdict_code} key={verdict.verdict_code}>{verdict.label}</option>
            ))}
          </select>
          <input
            value={bulkReEvaluateAt}
            onChange={(event) => setBulkReEvaluateAt(event.target.value)}
            placeholder="re_evaluate_at"
            type="date"
          />
          <textarea
            value={stripRequestPrefix(bulkNotes)}
            onChange={(event) => {
              setBulkNotes(event.target.value);
              openBulkPanel();
            }}
            placeholder={requiresNotes ? "Notes required" : "Notes"}
          />
          {bulkRowError ? (
            <div className="audit-bulk-error">
              {bulkRowError.row_index !== undefined ? `Row ${bulkRowError.row_index + 1}: ` : null}
              {bulkRowError.message}
              {bulkRowError.current_verdict_code ? ` Current verdict: ${bulkRowError.current_verdict_code}` : null}
            </div>
          ) : null}
          <button onClick={applyBulkClassification} disabled={bulkApplyDisabled} type="button">
            Apply to selected
          </button>
        </div>
        <div className="table-wrap">
          <table className="audit-table">
            <thead>
              <tr>
                <th>Select</th>
                <th>FC client</th>
                <th>Service tags</th>
                <th>Group</th>
                <th>Anchor</th>
                <th>Open invoice</th>
                <th>Annual revenue</th>
                <th>Current verdict</th>
                <th>Re-evaluate</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.fc_client_id}>
                  <td>
                    <input
                      checked={Boolean(selectedRows[row.fc_client_id])}
                      onChange={(event) => toggleRow(row, event.target.checked)}
                      type="checkbox"
                      aria-label={`Select ${row.fc_client_name}`}
                    />
                  </td>
                  <td className="audit-client-cell">
                    <strong>{row.fc_client_name}</strong>
                    <span>{row.anchor_client_business_name ?? "No Anchor match"}</span>
                    <button className="audit-detail-button" onClick={() => loadCandidateDetail(row)} type="button">
                      Details
                    </button>
                  </td>
                  <td>{tagList(row.service_tags)}</td>
                  <td>{row.group_names?.length ? row.group_names.join(", ") : <span className="audit-muted">—</span>}</td>
                  <td>{statusBadge(row.anchor_display_status)}</td>
                  <td className="money-cell">{formatMoney(row.open_invoice_balance_amount, { dashZero: true })}</td>
                  <td className="money-cell">{formatMoney(row.estimated_annual_revenue)}</td>
                  <td>{verdictLabel(row, verdictMap)}</td>
                  <td>{formatDate(row.re_evaluate_at)}</td>
                </tr>
              ))}
              {rows.length ? null : (
                <tr>
                  <td className="empty" colSpan={9}>No audit candidates match the current filters</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {activeDetailClientId ? (
        <aside className="audit-detail-panel" aria-live="polite">
          <div className="audit-panel-header">
            <div>
              <h2>Candidate detail</h2>
              <span>{detailPayload?.candidate?.fc_client_name ?? `Client ${activeDetailClientId}`}</span>
            </div>
            <button className="btn" onClick={() => setActiveDetailClientId(null)} type="button">Close</button>
          </div>
          {detailLoading ? <p className="audit-muted">Loading detail...</p> : null}
          {detailError ? <div className="error-toast">{detailError}</div> : null}
          {detailPayload ? (
            <>
              <details className="audit-detail-section" open>
                <summary>Candidate summary</summary>
                <dl className="audit-detail-grid">
                  <dt>Current verdict</dt>
                  <dd>{verdictLabel(detailPayload.candidate, verdictMap)}</dd>
                  <dt>Default visibility</dt>
                  <dd>{detailPayload.candidate.default_visibility}</dd>
                  <dt>Annual revenue</dt>
                  <dd>{formatMoney(detailPayload.candidate.estimated_annual_revenue)}</dd>
                  <dt>Service tags</dt>
                  <dd>{tagList(detailPayload.candidate.service_tags)}</dd>
                </dl>
              </details>

              <details className="audit-detail-section">
                <summary>FC activity</summary>
                <dl className="audit-detail-grid">
                  <dt>Archived</dt>
                  <dd>{String(detailPayload.fc_activity?.fc_is_archived ?? false)}</dd>
                  <dt>Archived at</dt>
                  <dd>{formatDate(detailPayload.fc_activity?.fc_archived_at)}</dd>
                  <dt>Unarchived after archive</dt>
                  <dd>{String(detailPayload.fc_activity?.fc_unarchived_after_archive ?? false)}</dd>
                  <dt>Post-archive service delivery</dt>
                  <dd>{String(detailPayload.fc_activity?.has_post_archive_service_delivery ?? false)}</dd>
                </dl>
              </details>

              <details className="audit-detail-section" open>
                <summary>Anchor signals</summary>
                <dl className="audit-detail-grid">
                  <dt>Status</dt>
                  <dd>{statusBadge(detailPayload.anchor_signals?.anchor_display_status)}</dd>
                  <dt>Relationship</dt>
                  <dd>{fieldValue(detailPayload.anchor_signals?.anchor_relationship_id)}</dd>
                  <dt>Invoice in 365d</dt>
                  <dd>{String(detailPayload.anchor_signals?.has_anchor_invoice_365d ?? false)}</dd>
                  <dt>Open invoice balance</dt>
                  <dd>{formatMoney(detailPayload.anchor_signals?.open_invoice_balance_amount, { dashZero: true })}</dd>
                </dl>
              </details>

              <details className="audit-detail-section">
                <summary>Group signals</summary>
                <dl className="audit-detail-grid">
                  <dt>Active group membership</dt>
                  <dd>{String(detailPayload.group_signals?.has_active_group_membership ?? false)}</dd>
                  <dt>Groups</dt>
                  <dd>{detailPayload.group_signals?.group_names?.length ? detailPayload.group_signals.group_names.join(", ") : <span className="audit-muted">—</span>}</dd>
                  <dt>Billed parent</dt>
                  <dd>{fieldValue(detailPayload.group_signals?.billed_parent_name)}</dd>
                </dl>
              </details>

              <details className="audit-detail-section" open>
                <summary>Transition rules</summary>
                {detailPayload.transition_rules?.length ? (
                  <ul className="audit-detail-list">
                    {detailPayload.transition_rules.map((rule) => (
                      <li key={`${rule.from_verdict_code}-${rule.signal_name}-${rule.to_verdict_code}`}>
                        <strong>{rule.signal_name}</strong>
                        <span>{rule.from_verdict_code} to {rule.to_verdict_code}</span>
                        {transitionBadge(rule)}
                      </li>
                    ))}
                  </ul>
                ) : <p className="audit-muted">No transition rules apply to the current verdict.</p>}
              </details>

              <details className="audit-detail-section">
                <summary>Classification history</summary>
                {detailPayload.classification_history_truncated ? (
                  <p className="audit-muted">Showing 100 most recent of {detailPayload.classification_history_total_count} classifications</p>
                ) : (
                  <p className="audit-muted">{detailPayload.classification_history_total_count ?? 0} total classifications</p>
                )}
                {detailPayload.classification_history?.length ? (
                  <ul className="audit-detail-list">
                    {detailPayload.classification_history.map((classification) => (
                      <li key={classification.classification_id}>
                        <strong>{classification.verdict_code}</strong>
                        <span>{formatDate(classification.classified_at)} by {classification.classified_by ?? "unknown"}</span>
                        <span>{stripRequestPrefix(classification.notes) || <span className="audit-muted">No notes</span>}</span>
                      </li>
                    ))}
                  </ul>
                ) : <p className="audit-muted">No prior classifications</p>}
              </details>

              <details className="audit-detail-section">
                <summary>Recent service tasks</summary>
                {detailPayload.recent_service_tasks?.length ? (
                  <ul className="audit-detail-list">
                    {detailPayload.recent_service_tasks.map((task) => (
                      <li key={task.fc_task_id ?? `${task.fc_client_id}-${task.completed_at}`}>
                        <strong>{task.task_name ?? task.task_title ?? task.fc_task_id ?? "Service task"}</strong>
                        <span>{formatDate(task.completed_at)} · {task.task_kind}</span>
                      </li>
                    ))}
                  </ul>
                ) : <p className="audit-muted">No recent service tasks</p>}
              </details>
            </>
          ) : null}
        </aside>
      ) : null}

      {diagnosticsOpen ? (
        <aside className="audit-diagnostics-panel" aria-live="polite">
          <div className="audit-panel-header">
            <div>
              <h2>QBO category diagnostics</h2>
              <span>{qboCategoryGaps.length} gap rows grouped by gap_origin</span>
            </div>
            <button className="btn" onClick={() => setDiagnosticsOpen(false)} type="button">Close</button>
          </div>
          {diagnosticsError ? <div className="error-toast">{diagnosticsError}</div> : null}
          {diagnosticsLoading ? <p className="audit-muted">Loading diagnostics...</p> : null}
          {Object.entries(groupedQboCategoryGaps).map(([gap_origin, gapRows]) => (
            <details className="audit-detail-section" key={gap_origin} open>
              <summary>{gap_origin} ({gapRows.length})</summary>
              <ul className="audit-detail-list">
                {gapRows.map((gap) => (
                  <li key={`${gap.gap_origin}-${gap.qbo_product_name_raw}`}>
                    <strong>{gap.qbo_product_name_raw ?? "Unknown product"}</strong>
                    <span>{gap.qbo_product_match_status} · {gap.revenue_event_count} events · {formatMoney(gap.total_source_amount)}</span>
                    <span>Leaf: {gap.qbo_product_leaf_name ?? "—"} · Category: {gap.qbo_category_path ?? "—"}</span>
                  </li>
                ))}
              </ul>
            </details>
          ))}
        </aside>
      ) : null}
    </main>
  );
}
