defmodule Responder.CapabilityContractTest do
  use ExUnit.Case, async: true

  @contract_path "docs/elixir-go-capability-contract.json"
  @document_path "docs/elixir-go-capability-contract.md"

  @design_capabilities ~w(
    app-home-and-web-control-plane
    attachments-and-screenshots
    channel-setup-and-conversational-configuration
    cleanup
    contextual-next-step-controls
    cross-channel-memory
    diff-and-draft-pr-controls
    durable-preferences-and-rules
    emisar-actions-and-approvals
    engineering-changes
    freeform-operator-guidance
    generated-charts-and-files
    incident-timeline-and-postmortem
    incidents
    mentions-dms-and-proactive-messages
    model-choice-and-byoc
    multi-repository-work
    pr-checks-merge-deployment-and-verification
    progress-updates
    reactions
    runbook-control-plane-work
    scheduled-and-recurring-work
    standing-assignments
    thread-and-channel-switching
  )

  @required_behaviors ~w(
    app-home-navigation-and-recovery-controls
    channel-setup-and-configuration
    contextual-next-step-controls
    conversation-summaries-and-rollups
    coop-work-and-same-session-repair
    durable-preferences-rules-and-guidance
    engineering-task-fork-diff-and-draft-pr
    episode-lifecycle-and-destination
    generic-admission-and-model-routing
    generic-authenticated-webhook-ingress
    github-bounded-context-and-search
    github-comments-reviews-inline-and-reactions
    github-confirmation-backed-actions
    github-replies-reactions-and-idempotency
    goal-planning-and-dependencies
    governed-emisar-actions-and-approvals
    grafana-lifecycle-webhook-adapter
    incident-rooms-timeline-and-postmortem
    input-attachments-and-screenshots
    local-control-plane-and-conversation-lab
    mapped-json-webhook-adapters
    memory-review-controls
    model-choice-byoc-and-execution-metadata
    multi-repository-orchestration
    operator-incident-schedule-repository-views
    operator-preflight-status-failure-replay
    output-files-images-and-charts
    privacy-aware-cross-channel-recall
    publication-conflict-recovery-and-deployment-verification
    release-backup-restore-proof
    repository-freshness-receipts
    responder-mcp-state-tools
    retention-cleanup-and-restart-recovery
    schedules-run-now-replace-and-history
    slack-app-home-core
    slack-message-shortcut
    slack-messages-edits-deletes
    slack-progress-and-bounded-admission
    slack-replies-reactions-and-idempotency
    slack-task-and-incident-cards
    slack-thread-and-channel-continuation
    standing-assignments
    subscriptions-and-poll-fallback
  )

  @open_tasks ~w(
    2026-09-04-complete-the-local-operator-product-for-incident
    2026-09-04-finish-goals-and-multi-repository-orchestration
    2026-09-04-finish-schedules-subscriptions-and-execution-his
  )

  test "the P0 and P1 replacement contract stays exact and evidence backed" do
    contract = @contract_path |> File.read!() |> Jason.decode!()
    capabilities = contract["capabilities"]

    assert contract["version"] == 1
    assert contract["status_semantics"]["implemented"] =~ "deterministic proof"
    assert is_list(capabilities)

    assert capabilities |> Enum.map(& &1["id"]) |> Enum.sort() ==
             Enum.sort(@required_behaviors)

    assert capabilities
           |> Enum.flat_map(& &1["design_capabilities"])
           |> Enum.uniq()
           |> Enum.sort() ==
             Enum.sort(@design_capabilities)

    assert capabilities
           |> Enum.map(& &1["next_task"])
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.sort() ==
             Enum.sort(@open_tasks)

    Enum.each(capabilities, &assert_capability!/1)
  end

  test "the readable contract and primary docs point to the checked source of truth" do
    contract = @contract_path |> File.read!() |> Jason.decode!()
    document = File.read!(@document_path)
    readme = File.read!("README.md")
    architecture = File.read!("docs/architecture-next.md")

    assert document =~ "Implementation status is not deployment proof"
    assert readme =~ "elixir-go-capability-contract.md"
    assert architecture =~ "elixir-go-capability-contract.md"

    Enum.each(contract["capabilities"], fn capability ->
      assert document =~ "`#{capability["id"]}`"
    end)
  end

  defp assert_capability!(capability) do
    assert capability["priority"] in ["P0", "P1"]
    assert capability["status"] in ["implemented", "partial"]
    assert nonempty?(capability["required_behavior"])
    assert nonempty_list?(capability["design_capabilities"])
    assert nonempty_list?(capability["origin_refs"])
    assert nonempty_list?(capability["implementation_refs"])
    assert nonempty_list?(capability["proof_refs"])

    Enum.each(
      capability["origin_refs"] ++ capability["implementation_refs"] ++ capability["proof_refs"],
      fn path -> assert File.regular?(path), "missing capability evidence #{path}" end
    )

    case capability["status"] do
      "implemented" ->
        assert is_nil(capability["gap"])
        assert is_nil(capability["next_task"])

      "partial" ->
        assert nonempty?(capability["gap"])
        assert capability["next_task"] in @open_tasks
    end
  end

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp nonempty_list?(value),
    do: is_list(value) and value != [] and Enum.all?(value, &nonempty?/1)
end
