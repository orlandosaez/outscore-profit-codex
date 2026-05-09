const REVIEW_STEPS = [
  { n: 1, label: "Period", anchor: "review-period" },
  { n: 2, label: "Company tiles", anchor: "review-tiles" },
  { n: 3, label: "Ratio Summary", anchor: "review-ratio" },
  { n: 4, label: "Pending / FC Queue", anchor: "review-fc-queue" },
  { n: 5, label: "Per-Client GP", anchor: "review-client-gp" },
  { n: 6, label: "Per-Staff GP", anchor: "review-staff-gp" },
  { n: 7, label: "Comp Ledger", anchor: "review-comp" },
  { n: 8, label: "W2 Watch", anchor: "review-w2" },
];

export const REVIEW_ANCHORS = Object.fromEntries(
  REVIEW_STEPS.map((step) => [step.anchor, step.anchor]),
);

export default function ReviewChecklist() {
  return (
    <nav aria-label="Monthly review checklist" className="review-checklist">
      <span className="review-checklist-eyebrow">Monthly review · 8 steps</span>
      <ol className="review-checklist-steps">
        {REVIEW_STEPS.map((step) => (
          <li key={step.n}>
            <a className="review-step" href={`#${step.anchor}`}>
              <span aria-hidden="true" className="review-step-num">{step.n}</span>
              <span className="review-step-label">{step.label}</span>
            </a>
          </li>
        ))}
      </ol>
    </nav>
  );
}
