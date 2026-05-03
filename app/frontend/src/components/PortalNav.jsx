import { NavLink } from "react-router-dom";

const NAV_LINKS = [
  { to: "/", label: "Dashboard", end: true },
  { to: "/admin/recognition", label: "Manual Recognition" },
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
