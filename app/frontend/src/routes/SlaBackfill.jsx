import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

import { EmptyRow, EmptyState } from "../components/EmptyState.jsx";

const apiBase = import.meta.env.VITE_PROFIT_API_BASE ?? "/api";
const backfillEndpoint = `${apiBase}/profit/admin/sla/backfill`;

export default function SlaBackfill() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function loadBackfill() {
    setLoading(true);
    setError("");
    try {
      const response = await fetch(backfillEndpoint);
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.detail?.message ?? `SLA backfill request failed: ${response.status}`);
      setRows(payload.rows ?? []);
    } catch (err) {
      setError(err instanceof Error ? err.message : "SLA backfill request failed");
      setRows([]);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    loadBackfill();
  }, []);

  return (
    <main className="pipeline-page">
      <header className="manual-recognition-hero">
        <div>
          <h1>Anchor Backfill</h1>
          <span>Read-only queue for QBO-settled clients that need Anchor convergence.</span>
        </div>
        <Link className="btn btn-secondary" to="/admin/sla">Back to SLA</Link>
      </header>

      {error ? <div className="error-toast">{error}</div> : null}
      <section className="panel">
        <div className="panel-title">
          <h2>Backfill queue</h2>
        </div>
        {loading ? (
          <EmptyState label="Loading Anchor backfill queue" hint="Fetching the latest read-only queue snapshot." />
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Client</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {rows.length ? (
                  rows.slice(0, 10).map((row, index) => (
                    <tr key={row.id ?? row.fc_client_id ?? index}>
                      <td>{row.client_name ?? row.group_name ?? "Anchor backfill row"}</td>
                      <td>Task 6 panel detail</td>
                    </tr>
                  ))
                ) : (
                  <EmptyRow colSpan={2} label="No Anchor backfill rows" hint="No QBO-settled clients currently need Anchor backfill." />
                )}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </main>
  );
}
