import { BrowserRouter, Route, Routes } from "react-router-dom";

import PortalNav from "./components/PortalNav.jsx";
import AuditDashboard from "./routes/AuditDashboard.jsx";
import Dashboard from "./routes/Dashboard.jsx";
import DataQuality from "./routes/DataQuality.jsx";
import ManualRecognition from "./routes/ManualRecognition.jsx";
import PipelineRuns from "./routes/PipelineRuns.jsx";
import SlaBackfill from "./routes/SlaBackfill.jsx";
import SlaDashboard from "./routes/SlaDashboard.jsx";
import WeeklyReview from "./routes/WeeklyReview.jsx";

const basename = import.meta.env.VITE_BASE_PATH ?? "/";

export default function App() {
  return (
    <BrowserRouter basename={basename}>
      <PortalNav />
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/admin/audit" element={<AuditDashboard />} />
        <Route path="/admin/data-quality" element={<DataQuality />} />
        <Route path="/admin/pipeline" element={<PipelineRuns />} />
        <Route path="/admin/pipeline/:pipelineRunId" element={<PipelineRuns />} />
        <Route path="/admin/recognition" element={<ManualRecognition />} />
        <Route path="/admin/sla" element={<SlaDashboard />} />
        <Route path="/admin/sla/backfill" element={<SlaBackfill />} />
        <Route path="/admin/weekly-review" element={<WeeklyReview />} />
      </Routes>
    </BrowserRouter>
  );
}
