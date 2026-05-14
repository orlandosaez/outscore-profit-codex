import { NavLink } from "react-router-dom";

const NAV_LINKS = [
  { to: "/", label: "Dashboard", end: true },
  { to: "/admin/audit", label: "Audit" },
  { to: "/admin/data-quality", label: "Data Quality" },
  { to: "/admin/pipeline", label: "Pipeline" },
  { to: "/admin/recognition", label: "Manual Recognition" },
  { to: "/admin/sla", label: "SLA" },
  { to: "/admin/subscription-reserve", label: "Subscription Reserve" },
  { to: "/admin/weekly-review", label: "Weekly Review" },
];

export default function PortalNav() {
  return (
    <nav className="portal-nav" aria-label="Profit Admin sections">
      <div className="portal-nav-brand">Outscore Profit Admin</div>
      <ul className="portal-nav-links">
        {NAV_LINKS.map((link) => (
          <li key={link.to}>
            <NavLink
              to={link.to}
              end={link.end}
              className={({ isActive }) => (
                isActive
                  ? "portal-nav-link portal-nav-link-active"
                  : "portal-nav-link"
              )}
            >
              {link.label}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  );
}
