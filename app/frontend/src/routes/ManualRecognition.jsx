import { useEffect, useMemo, useState } from "react";
import { CheckCircle2, FileCheck2, RefreshCw, Search, X } from "lucide-react";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const pendingEndpoint = `${apiBase}/profit/admin/recognition/pending`;
const overrideEndpoint = `${apiBase}/profit/admin/recognition/manual-override`;
const overridesEndpoint = `${apiBase}/profit/admin/recognition/manual-overrides`;

const REASON_OPTIONS = [
  ["backbill_pre_engagement", "Backbill pre-engagement", "Work delivered before Anchor agreement was signed."],
  ["client_operational_change", "Client operational change", "Mid-engagement billing/structure/scope change broke recognition."],
  ["entity_restructure", "Entity restructure", "Client split, merged, renamed, or moved entities."],
  ["service_outside_fc_scope", "Service outside FC scope", "Service genuinely delivered but never tracked in FC."],
  ["fc_classifier_gap", "FC classifier gap", "FC task exists/completed, classifier did not recognize it."],
  ["voided_invoice_replacement", "Voided invoice replacement", "Voided invoice replaced with another, recognition follows replacement."],
  ["billing_amount_adjustment", "Billing amount adjustment", "Credit/discount/extra charge needs override."],
  ["other", "Other", "Catch-all (requires 20+ characters of notes)."],
];

const STATUS_LABEL = {
  pending_bookkeeping_completion: "Pending bookkeeping",
  pending_payroll_processed: "Pending payroll",
  pending_tax_completion: "Tax deferred",
  pending_advisory_review: "Pending advisory",
  recognized_by_completion_trigger: "Recognized (FC)",
  recognized_by_manual_override: "Recognized (manual)",
  excluded_voided_invoice: "Excluded (void)",
};

const consolidatedTooltip = "One of N revenue events under the same Anchor relationship, service type, and period. Common when one Anchor invoice covers multiple FC entities (e.g., DVH Investing billed for three separate tax returns). Match by source amount when recognizing.";

const money = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

function formatMoney(value) {
  return money.format(Number(value ?? 0));
}

function monthLabel(value) {
  if (!value) return "n/a";
  return new Date(`${value}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    year: "numeric",
  });
}

function statusLabel(value) {
  return STATUS_LABEL[value] ?? value ?? "Unknown";
}

function shortKey(key) {
  if (!key) return "";
  return key.length > 12 ? `…${key.slice(-8)}` : key;
}

export default function ManualRecognition() {
  const [pendingRows, setPendingRows] = useState([]);
  const [recentOverrides, setRecentOverrides] = useState([]);
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [clientFilter, setClientFilter] = useState("");
  const [serviceFilter, setServiceFilter] = useState("");
  const [periodFilter, setPeriodFilter] = useState("");
  const [selectedReason, setSelectedReason] = useState("");
  const [notes, setNotes] = useState("");
  const [reference, setReference] = useState("");
  const [showReasonLegend, setShowReasonLegend] = useState(false);
  const [showTaxDeferred, setShowTaxDeferred] = useState(false);
  const [showRecognitionPatterns, setShowRecognitionPatterns] = useState(false);
  const [toast, setToast] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  const approveDisabled = !selectedEvent
    || !selectedReason
    || !notes.trim()
    || (selectedReason === "other" && notes.trim().length < 20);

  async function loadPending() {
    const params = new URLSearchParams();
    if (clientFilter.trim()) params.set("client_filter", clientFilter.trim());
    if (serviceFilter) params.set("service_filter", serviceFilter);
    if (periodFilter) params.set("period_filter", periodFilter);
    const query = params.toString();
    const response = await fetch(query ? `${pendingEndpoint}?${query}` : pendingEndpoint);
    if (!response.ok) throw new Error(`Pending recognition request failed: ${response.status}`);
    const payload = await response.json();
    setPendingRows(payload.rows ?? []);
  }

  async function loadRecentOverrides() {
    const response = await fetch(overridesEndpoint);
    if (!response.ok) throw new Error(`Recent overrides request failed: ${response.status}`);
    const payload = await response.json();
    setRecentOverrides(payload.rows ?? []);
  }

  async function refreshPage() {
    setLoading(true);
    setError("");
    try {
      await Promise.all([loadPending(), loadRecentOverrides()]);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Manual recognition refresh failed");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    refreshPage();
  }, []);

  function openEvent(row) {
    setSelectedEvent(row);
    resetApprovalForm();
    setToast("");
    setError("");
  }

  function resetApprovalForm() {
    setSelectedReason("");
    setNotes("");
    setReference("");
    setShowReasonLegend(false);
  }

  function dismissPanel() {
    setSelectedEvent(null);
    resetApprovalForm();
  }

  useEffect(() => {
    if (!selectedEvent) return undefined;

    function handleEscape(event) {
      if (event.key === "Escape") {
        dismissPanel();
      }
    }

    window.addEventListener("keydown", handleEscape);
    return () => window.removeEventListener("keydown", handleEscape);
  }, [selectedEvent]);

  function reasonDescription(value) {
    return REASON_OPTIONS.find(([optionValue]) => optionValue === value)?.[2] ?? "";
  }

  async function approveSelectedEvent() {
    if (approveDisabled) return;
    setLoading(true);
    setError("");
    try {
      const response = await fetch(overrideEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          revenue_event_key: selectedEvent.revenue_event_key,
          reason_code: selectedReason,
          notes,
          reference: reference || null,
        }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail ?? "Manual override failed");
      setToast(`Recognized ${payload.event.revenue_event_key} as ${payload.event.recognition_status}`);
      dismissPanel();
      await refreshPage();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Manual override failed");
    } finally {
      setLoading(false);
    }
  }

  const eventCountLabel = useMemo(
    () => `${pendingRows.filter((row) => showTaxDeferred || row.recognition_status !== "pending_tax_completion").length} pending events`,
    [pendingRows, showTaxDeferred],
  );

  const visiblePendingRows = useMemo(
    () => pendingRows.filter((row) => showTaxDeferred || row.recognition_status !== "pending_tax_completion"),
    [pendingRows, showTaxDeferred],
  );

  const hasConsolidated = useMemo(
    () => visiblePendingRows.some((row) => Number(row.sibling_event_count ?? 0) > 1),
    [visiblePendingRows],
  );

  useEffect(() => {
    if (hasConsolidated) {
      setShowRecognitionPatterns(true);
    }
  }, [hasConsolidated]);

  const siblingEvents = useMemo(() => {
    if (!selectedEvent || Number(selectedEvent.sibling_event_count ?? 0) <= 1) {
      return [];
    }
    return pendingRows
      .filter((row) => (
        row.anchor_relationship_id === selectedEvent.anchor_relationship_id
        && row.macro_service_type === selectedEvent.macro_service_type
        && row.candidate_period_month === selectedEvent.candidate_period_month
      ))
      .sort((a, b) => Number(b.source_amount ?? 0) - Number(a.source_amount ?? 0));
  }, [pendingRows, selectedEvent]);

  return (
    <main className="manual-recognition-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Manual Recognition</h1>
          <span>Use only when FC trigger cannot fire automatically. All approvals are logged.</span>
        </div>
        <div className="manual-hero-actions">
          <button className="icon-button" onClick={refreshPage} disabled={loading} title="Refresh manual recognition data" type="button">
            <RefreshCw size={18} aria-hidden="true" />
          </button>
        </div>
      </header>

      {toast ? <div className="success-toast"><CheckCircle2 size={16} aria-hidden="true" />{toast}</div> : null}
      {error ? <div className="error-toast">{error}</div> : null}

      <section className="panel manual-filter-panel">
        <div className="panel-title">
          <Search size={18} aria-hidden="true" />
          <h2>Pending revenue events</h2>
          <span>{eventCountLabel}</span>
        </div>
        <div className="manual-filters">
          <input value={clientFilter} onChange={(event) => setClientFilter(event.target.value)} placeholder="Client" />
          <select value={serviceFilter} onChange={(event) => setServiceFilter(event.target.value)}>
            <option value="">All services</option>
            <option value="bookkeeping">Bookkeeping</option>
            <option value="payroll">Payroll</option>
            <option value="tax">Tax</option>
            <option value="advisory">Advisory</option>
            <option value="other">Other</option>
          </select>
          <input value={periodFilter} onChange={(event) => setPeriodFilter(event.target.value)} placeholder="YYYY-MM-01" />
          <button onClick={refreshPage} disabled={loading} type="button">Apply filters</button>
        </div>
        <div className="manual-filter-options">
          <label className="inline-toggle">
            <input
              checked={showTaxDeferred}
              onChange={(event) => setShowTaxDeferred(event.target.checked)}
              type="checkbox"
            />
            Show tax-deferred events
          </label>
          <span>Tax-deferred events are hidden by default because they usually need filing/extension confirmation, not manual override.</span>
        </div>
        <p className="panel-note">
          Prefer FC trigger approval for normal bookkeeping, payroll, tax, and advisory completion rows. Use manual recognition only when a system trigger cannot reasonably fire.
        </p>
        <button
          className="disclosure-button"
          onClick={() => setShowRecognitionPatterns((current) => !current)}
          type="button"
        >
          <span aria-hidden="true">{showRecognitionPatterns ? "v" : ">"}</span>
          Recognition patterns
        </button>
        {showRecognitionPatterns ? (
          <div className="recognition-patterns">
            <h3>Consolidated billing pattern</h3>
            <p>
              When one Anchor invoice covers multiple FC entities (e.g., DVH Investing&apos;s invoice covers DVH, NDH, and Hornauer tax returns), the revenue events live under the BILLED entity, not the FC entity. Each FC trigger for the actual entity fires but cannot find its matching revenue event. To recognize, find the line item under the billed entity by matching source_amount to the actual return ($650 = Hornauer 1040, $350 = NDH 1065, etc.). Use reason code client_operational_change and note which return the line item corresponds to.
            </p>
          </div>
        ) : null}
        <div className="table-wrap">
          <table className="manual-recognition-table">
            <thead>
              <tr>
                <th>Client</th>
                <th>Service</th>
                <th>Period</th>
                <th>Source amount</th>
                <th>Cash allocated</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {visiblePendingRows.map((row) => (
                <tr key={row.revenue_event_key} onClick={() => openEvent(row)}>
                  <td className="manual-client-cell">
                    {row.anchor_client_business_name ?? "Unassigned"}
                    {Number(row.sibling_event_count ?? 0) > 1 ? (
                      <span className="consolidated-badge" title={consolidatedTooltip}>
                        Consolidated ({row.sibling_event_count})
                      </span>
                    ) : null}
                  </td>
                  <td>{row.macro_service_type}</td>
                  <td>{monthLabel(row.candidate_period_month)}</td>
                  <td className="money-cell">{formatMoney(row.source_amount)}</td>
                  <td className="money-cell">{formatMoney(row.cash_allocated)}</td>
                  <td title={row.recognition_status}>{statusLabel(row.recognition_status)}</td>
                </tr>
              ))}
              {visiblePendingRows.length ? null : (
                <tr>
                  <td className="empty" colSpan={6}>No pending revenue events loaded</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>

      {selectedEvent ? (
        <aside className="manual-override-panel">
          <div className="panel-title manual-panel-title">
            <div className="panel-title">
              <FileCheck2 size={18} aria-hidden="true" />
              <h2>Approve and Recognize</h2>
            </div>
            <button className="icon-button" onClick={dismissPanel} type="button" aria-label="Close" title="Close">
              <X size={18} aria-hidden="true" />
            </button>
          </div>
          <dl className="manual-event-details">
            <dt>Revenue event</dt>
            <dd className="key-value" title={selectedEvent.revenue_event_key}>{shortKey(selectedEvent.revenue_event_key)}</dd>
            <dt>Client</dt>
            <dd>{selectedEvent.anchor_client_business_name ?? "Unassigned"}</dd>
            <dt>Amount</dt>
            <dd className="money-value">{formatMoney(selectedEvent.source_amount)}</dd>
            <dt>Status</dt>
            <dd title={selectedEvent.recognition_status}>{statusLabel(selectedEvent.recognition_status)}</dd>
          </dl>
          {siblingEvents.length ? (
            <section className="sibling-events-panel">
              <h3>Sibling events</h3>
              <p>This event is part of a consolidated invoice. Sibling events:</p>
              <ul>
                {siblingEvents.map((row) => (
                  <li
                    className={row.revenue_event_key === selectedEvent.revenue_event_key ? "selected-sibling-event" : ""}
                    key={row.revenue_event_key}
                  >
                    <strong>{formatMoney(row.source_amount)}</strong>
                    <span className="key-value" title={row.revenue_event_key}>{shortKey(row.revenue_event_key)}</span>
                    {row.revenue_event_key === selectedEvent.revenue_event_key ? <em><span aria-hidden="true">●</span> selected</em> : null}
                  </li>
                ))}
              </ul>
            </section>
          ) : null}
          <label>
            Reason code
            <select value={selectedReason} onChange={(event) => setSelectedReason(event.target.value)}>
              <option value="">Select reason</option>
              {REASON_OPTIONS.map(([value, label, description]) => (
                <option value={value} key={value} title={description}>{label}</option>
              ))}
            </select>
          </label>
          {selectedReason ? <p className="reason-hint">{reasonDescription(selectedReason)}</p> : null}
          <button
            className="link-button"
            onClick={() => setShowReasonLegend((current) => !current)}
            type="button"
          >
            What do these mean?
          </button>
          {showReasonLegend ? (
            <dl className="reason-legend">
              {REASON_OPTIONS.map(([value, label, description]) => (
                <div key={value}>
                  <dt>{label}</dt>
                  <dd>{description}</dd>
                </div>
              ))}
            </dl>
          ) : null}
          <label>
            Notes
            <textarea value={notes} onChange={(event) => setNotes(event.target.value)} />
          </label>
          <label>
            Reference
            <input value={reference} onChange={(event) => setReference(event.target.value)} placeholder="Email subject, ticket, or link" />
          </label>
          <div className="manual-action-row">
            <button onClick={dismissPanel} type="button">Cancel</button>
            <button onClick={approveSelectedEvent} disabled={approveDisabled} type="button">Approve and Recognize</button>
          </div>
        </aside>
      ) : null}

      <section className="panel">
        <div className="panel-title">
          <FileCheck2 size={18} aria-hidden="true" />
          <h2>Recent overrides</h2>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Approved</th>
                <th>Event</th>
                <th>Client</th>
                <th>Service</th>
                <th>Amount</th>
                <th>Reason</th>
                <th>Approved by</th>
              </tr>
            </thead>
            <tbody>
              {recentOverrides.map((row) => (
                <tr key={row.recognition_trigger_key}>
                  <td>{row.approved_at}</td>
                  <td>{row.revenue_event_key}</td>
                  <td>{row.anchor_client_business_name ?? "Unassigned"}</td>
                  <td>{row.macro_service_type}</td>
                  <td>{formatMoney(row.source_amount)}</td>
                  <td>{row.manual_override_reason_code}</td>
                  <td>{row.approved_by}</td>
                </tr>
              ))}
              {recentOverrides.length ? null : (
                <tr>
                  <td className="empty" colSpan={7}>No manual recognition overrides loaded</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </section>
    </main>
  );
}
