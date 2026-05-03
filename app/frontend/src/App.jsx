import { BrowserRouter, Route, Routes } from "react-router-dom";

import PortalNav from "./components/PortalNav.jsx";
import Dashboard from "./routes/Dashboard.jsx";
import ManualRecognition from "./routes/ManualRecognition.jsx";

const basename = import.meta.env.VITE_BASE_PATH ?? "/";

export default function App() {
  return (
    <BrowserRouter basename={basename}>
      <PortalNav />
      <Routes>
        <Route path="/" element={<Dashboard />} />
        <Route path="/admin/recognition" element={<ManualRecognition />} />
      </Routes>
    </BrowserRouter>
  );
}
