defmodule Ryker.ControlPlane.EvidenceTest do
  @moduledoc """
  The shared meaning of the dimensions every evidence card repeats.

  The costly confusion is always the same shape: an absence rendered as a
  number. "0 rules matched" says somebody looked and found nothing; "rule
  evaluation was not recorded" says nobody looked. An operator who reads the
  second as the first stops investigating. These tests pin the distinction in
  one place so eighteen cards cannot each re-decide it.
  """
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.Evidence

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
    for state <- [:not_recorded, :unavailable, :redacted] do
      described = Evidence.availability(state)
      refute described.known?, "#{state} must not read as known evidence"
      refute described.label == "0"
    end

    assert Evidence.availability(:recorded).known?
  end

  test "unavailable, redacted and never-recorded stay distinguishable" do
    labels =
      for state <- [:not_recorded, :unavailable, :redacted],
          do: Evidence.availability(state).label

    assert labels == Enum.uniq(labels)
  end

  test "not applicable and not reached are separate facts" do
    labels =
      for state <- [:not_applicable, :not_reached],
          do: Evidence.applicability(state).label

    assert labels == Enum.uniq(labels)
    # A neutral non-match is ordinary information, not a failure.
    assert Enum.all?([:not_applicable, :not_reached], &(Evidence.applicability(&1).tone == nil))
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
end
