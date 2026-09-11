defmodule Responder.ControlPlane.EvidenceTest do
  @moduledoc """
  The shared meaning of the dimensions every evidence card repeats.

  The costly confusion is always the same shape: an absence rendered as a
  number. "0 rules matched" says somebody looked and found nothing; "rule
  evaluation was not recorded" says nobody looked. An operator who reads the
  second as the first stops investigating. These tests pin the distinction in
  one place so eighteen cards cannot each re-decide it.
  """
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.Evidence

  test "an unknown count is never a zero" do
    unknown = Evidence.count(nil)
    zero = Evidence.count(0)

    refute unknown.known?
    assert unknown.label == "Not recorded"
    assert unknown.value == nil

    assert zero.known?
    assert zero.label == "0"
  end

  test "every availability except recorded means the reader is looking at an absence" do
    for state <- [:not_recorded, :upstream_elided, :loading, :unavailable, :expired, :redacted] do
      described = Evidence.availability(state)
      refute described.known?, "#{state} must not read as known evidence"
      refute described.label == "0"
      refute Evidence.known?(state)
    end

    assert Evidence.availability(:recorded).known?
    assert Evidence.known?(:recorded)
  end

  test "expired, redacted and never-recorded stay distinguishable" do
    labels =
      for state <- [:not_recorded, :upstream_elided, :unavailable, :expired, :redacted],
          do: Evidence.availability(state).label

    assert labels == Enum.uniq(labels)
  end

  test "eligible is included plus omitted only over one complete disjoint set" do
    complete = Evidence.selection(included: 3, omitted: 1)
    assert complete.eligible.value == 4

    partial = Evidence.selection(included: 3, omitted: 1, complete_set: false)
    refute partial.eligible.known?
    assert partial.eligible.label == "Not recorded"
    assert partial.included.value == 3
  end

  test "a shortened partial is included content, not an extra omission" do
    # Counting a shortened partial as omitted invented omissions nobody recorded
    # and made the arithmetic on the card stop adding up.
    selection = Evidence.selection(included: 4, omitted: 0, shortened: 2)

    assert selection.included.value == 4
    assert selection.omitted.value == 0
    assert selection.eligible.value == 4
    assert selection.shortened.value == 2
    assert selection.shortened.scope == :included
  end

  test "execution says what happened to this operation, not whether it was right" do
    completed = Evidence.execution(:completed)
    assert completed.state == :completed
    # A green tick already says it. Repeating "Passed" beside it is the same
    # fact twice and pushes the reasons that are not obvious off the card.
    assert completed.icon_only
    refute Evidence.execution(:failed).icon_only
    assert Evidence.execution(:failed).tone == :bad
    assert Evidence.execution(:cancelled).tone == nil
  end

  test "not applicable, skipped and not reached are three separate facts" do
    labels =
      for state <- [:not_applicable, :skipped, :not_reached],
          do: Evidence.applicability(state).label

    assert labels == Enum.uniq(labels)
    # A neutral non-match is ordinary information, not a failure.
    assert Enum.all?(
             [:not_applicable, :skipped, :not_reached],
             &(Evidence.applicability(&1).tone == nil)
           )
  end

  test "live evidence carries when it was observed and historical evidence stays frozen" do
    at = ~U[2026-09-09 12:00:00Z]
    current = Evidence.snapshot(:current, observed_at: at)
    assert current.observed_at == at
    assert current.label == "Current as of"

    historical = Evidence.snapshot(:historical)
    assert historical.observed_at == nil
    assert historical.label == "As recorded"
  end

  test "a full prompt names the boundary it was captured at" do
    responder = Evidence.prompt_boundary(:responder_submission)
    assert responder.detail =~ "worker may add its own instructions"
    refute responder.label == Evidence.prompt_boundary(:provider_request).label
    assert Evidence.prompt_boundary(:not_recorded).label =~ "not recorded"
  end

  test "a redacted display reports the original's size, not a digest of itself" do
    described =
      Evidence.safe_artifact(%{
        state: :retained,
        redacted: true,
        original_bytes: 4_096,
        original_digest: String.duplicate("a", 64)
      })

    assert described.altered?
    assert described.copies == :displayed_safe_view
    assert described.original_bytes == 4_096
    assert described.original_label =~ "Original"
    assert described.note =~ "describe the original"
    assert described.availability.state == :redacted
  end

  test "an expired artifact is not a redacted one and neither is empty" do
    assert Evidence.safe_artifact(%{state: :expired}).availability.state == :expired
    assert Evidence.safe_artifact(%{state: :absent}).availability.state == :not_recorded
    assert Evidence.safe_artifact(%{state: :retained}).availability.state == :recorded
  end
end
