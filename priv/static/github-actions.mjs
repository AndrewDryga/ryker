import {keepPlanDraft} from "./github-plan-draft.mjs"

for (const form of document.querySelectorAll("[data-review-selection]")) {
  const button = form.querySelector("[data-fix-selected]");
  const countLabel = form.querySelector("[data-selection-count]");
  const maximum = Number(form.dataset.selectionLimit);
  const update = () => {
    const count = form.querySelectorAll('input[name="findings[]"]:checked').length;
    countLabel.textContent = count > maximum
      ? `${count} selected. Choose at most ${maximum} for one run.`
      : `${count} selected`;
    button.textContent = `Fix ${count} ${count === 1 ? "finding" : "findings"} in PR #${form.dataset.prNumber}`;
    button.disabled = count === 0 || count > maximum;
  };
  form.addEventListener("change", update);
  update();
}

const plan = document.querySelector("textarea[data-saved-plan]");
if (plan) {
  const implement = document.querySelector("[data-implement-plan]");
  const notice = document.querySelector("[data-plan-edit-notice]");
  keepPlanDraft(plan, implement, notice, document.querySelector("[data-plan-draft-recovery]"));
}
