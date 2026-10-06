defmodule Ryker.ControlPlane.RoutingReasonTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.RoutingReason

  # QA re-test, 2026-09-26: 26 timelines showed routing reasons in routing's
  # own terms ("no candidate episode is available"). These are reasons stored
  # on the live install (17 of 51 used such words); the stored decision stays
  # as it was, and only what a person reads changes.
  @harvested [
    {"The user requests recurring weekday incident-status posts at 9:00. Setting up the schedule and incident source requires tool-backed work, with timezone clarification if needed. No prior episode is offered.",
     "The user requests recurring weekday incident-status posts at 9:00. Setting up the schedule and incident source requires tool-backed work, with timezone clarification if needed."},
    {"The user explicitly requests investigation of whether yesterday's checkout readiness probe alert is related to the 08:00 deployment. This requires operational evidence and correlation; no candidate episode is available.",
     "The user explicitly requests investigation of whether yesterday's checkout readiness probe alert is related to the 08:00 deployment. This requires operational evidence and correlation."},
    {"The user explicitly requests a recurring weekday incident-status post. Setting up the schedule and incident source requires tool-backed work, and no existing episode is offered.",
     "The user explicitly requests a recurring weekday incident-status post. Setting up the schedule and incident source requires tool-backed work."},
    {"This edits the exact message owned by the candidate, correcting the alert time from 08:04 to 08:06 for the same deployment and readiness incident.",
     "This edits the exact message that belongs to the earlier request, correcting the alert time from 08:04 to 08:06 for the same deployment and readiness incident."},
    {"The user requests a new one-time schedule prepared for confirmation, which requires tool-backed work. The prior completed episodes concern separate reply and memory requests and do not own this scheduling request.",
     "The user requests a new one-time schedule prepared for confirmation, which requires tool-backed work. The prior finished requests concern separate reply and memory requests and do not own this scheduling request."},
    {"The message \"1\" has no clear referent in the supplied conversation. Ask a brief clarification; the evidence does not establish a follow-up to either offered episode.",
     "The message \"1\" has no clear referent in the supplied conversation. Ask a brief clarification; the evidence does not establish a follow-up to either earlier request."},
    {"The edit revises a source message owned by this episode and needs only the direct answer: 10.",
     "The edit revises a source message that belongs to this request and needs only the direct answer: 10."},
    {"The direct request to remember the staging account name acme-staging warrants a brief acknowledgement. Background learning handles retention; no investigation or episode is needed.",
     "The direct request to remember the staging account name acme-staging warrants a brief acknowledgement. Background learning handles retention; no investigation or request is needed."}
  ]

  test "a stored routing reason is said in plain words, and what only says nothing was offered is left out" do
    for {stored, shown} <- @harvested do
      assert RoutingReason.plain(stored) == shown
      refute RoutingReason.plain(stored) =~ ~r/episode|candidate/i
    end
  end

  test "a reason that only said nothing was offered is not shown at all" do
    assert RoutingReason.plain("No candidate episodes are provided.") == nil
    assert RoutingReason.plain("No existing episode was offered.") == nil
  end

  test "a reason already in plain words is shown as it was" do
    plain = "A direct question about this repository that can be answered from its code."
    assert RoutingReason.plain(plain) == plain
  end
end
