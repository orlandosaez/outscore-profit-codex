import { Link } from "react-router-dom";

export function EmptyState({ label, hint, cta }) {
  let ctaNode = null;
  if (cta) {
    if (cta.to) {
      ctaNode = (
        <Link className="empty-state-cta" to={cta.to}>
          {cta.label} <span aria-hidden="true">→</span>
        </Link>
      );
    } else if (cta.onClick) {
      ctaNode = (
        <button className="empty-state-cta" onClick={cta.onClick} type="button">
          {cta.label} <span aria-hidden="true">→</span>
        </button>
      );
    }
  }

  return (
    <div className="empty-state">
      <p className="empty-state-label">{label}</p>
      {hint ? <p className="empty-state-hint">{hint}</p> : null}
      {ctaNode}
    </div>
  );
}

export function EmptyRow({ colSpan, label, hint, cta }) {
  return (
    <tr>
      <td className="empty-cell" colSpan={colSpan}>
        <EmptyState cta={cta} hint={hint} label={label} />
      </td>
    </tr>
  );
}
