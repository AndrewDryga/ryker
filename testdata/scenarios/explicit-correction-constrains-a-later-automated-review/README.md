# Explicit correction reaches a later automated review

This synthetic composition preserves harvested correction wording and the notification shape from `testdata/learning/retained-rollout-correction.json`, then uses the retained tool observations of `deployment-review-finds-its-baseline-before-reporting-a-gap`.

The host adapter maps the notification run, repository, revision, bot identity and event clock to that recorded world. It places the correction before a new episode in another thread of the same conversation. The source observations and comparison are unchanged; this is not a claim that those two production runs were the same run. No source response was invented. Delivery uses the inert world adapter.

The first episode must save the explicit human rule. The second has no human asker: it must receive the rule, recover the baseline through retained source observations, compare the revisions, record an evidenced result, and deliver the requested outputs. `new_episode` selects forced Work routing only; a real admission model still makes its own routing decision.
