defmodule Ryker.ControlPlane.EpisodeTrace.Maintenance do
  @moduledoc """
  "Cleanup": what happened afterwards to the worker session and the working
  copy, at its own time. Closing is not removing, a kept workspace is not
  a failure, and a local session that never bound a remote one had nothing
  to delete.

  Each card says what happened in words; the record behind it sits in its
  Details (Andrew, 2026-09-26: the Cleanup chapter should be "fornestic and
  detailed like everything else"): the worker that held the session, the
  close and removal requests, what the removal plan found in the working
  copy with its fingerprints, the receipt that proves the outcome, and the
  tries and errors on the way.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.CoopFleet.Placement
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Retention.Custody
  alias Ryker.Work.Session

  @doc "Session close and workspace cleanup, each at the time it happened."
  def steps(sessions) do
    sessions = Enum.filter(sessions, &(&1.cleanup_status != :active))
    workers = workers(sessions)

    Enum.flat_map(sessions, fn session ->
      worker = Map.get(workers, session.id)
      kept_open(session, worker) ++ closed(session, worker) ++ outcome(session, worker)
    end)
  end

  # The worker a session was last placed on: cleanup runs only there.
  defp workers([]), do: %{}

  defp workers(sessions) do
    ids = Enum.map(sessions, & &1.id)

    Repo.all(
      from(placement in Placement,
        where: placement.session_id in ^ids,
        order_by: [asc: placement.session_id, desc: placement.generation],
        select: {placement.session_id, placement.worker_id}
      )
    )
    |> Enum.uniq_by(&elem(&1, 0))
    |> Map.new()
  end

  # A finished request's session stays open for a while in case the
  # conversation continues; until then it is waiting, not closed.
  defp kept_open(%Session{cleanup_status: :grace, closed_at: nil} = session, worker) do
    [
      step("maintenance-#{session.id}-kept-open", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "current",
        title: "Worker session kept open",
        summary:
          "The request ended. Ryker keeps its worker session open" <>
            until(session.discard_after) <>
            " in case the conversation continues, then closes it.",
        tone: nil,
        details:
          session_details(session, worker) ++
            compact_details([{"Kept open until", readable(session.discard_after)}])
      })
    ]
  end

  defp kept_open(_session, _worker), do: []

  defp closed(%Session{closed_at: nil}, _worker), do: []

  defp closed(session, worker) do
    [
      step("maintenance-#{session.id}-closed", :maintenance, session.closed_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "session closed",
        title: "Worker session closed",
        summary: closed_summary(session),
        tone: nil,
        details:
          session_details(session, worker) ++
            compact_details([
              {"Close request", close_request(session), identifier: true},
              {"Closed at revision", session.close_expected_revision},
              {"Kept open until", readable(session.discard_after)},
              {"Closed", readable(session.closed_at)}
            ])
      })
    ]
  end

  defp outcome(%Session{cleanup_status: :discarded} = session, worker) do
    receipt = session.cleanup_receipt || %{}
    {title, summary} = cleanup_outcome(receipt["kind"])

    [
      step("maintenance-#{session.id}-discarded", :maintenance, session.discarded_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: String.downcase(title),
        title: title,
        summary: summary <> plan_sentence(receipt["kind"], session.discard_plan),
        tone: nil,
        details:
          session_details(session, receipt["worker_id"] || worker) ++
            plan_details(session) ++
            compact_details([
              {"Receipt", receipt_words(receipt["kind"])},
              {"Worker reported", remote_words(receipt["remote_state"])},
              {"Removal request", receipt["operation_key"], identifier: true},
              {"Receipt fingerprint", session.cleanup_receipt_fingerprint, identifier: true},
              {"Settled", readable(session.discarded_at)}
            ])
      })
    ]
  end

  defp outcome(%Session{cleanup_status: :retained} = session, worker) do
    [
      step("maintenance-#{session.id}-retained", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "current",
        title: "Working copy kept",
        summary: retained_reason(session.retained_reason) <> recheck(session),
        tone: nil,
        details:
          session_details(session, worker) ++
            plan_details(session) ++
            compact_details([
              {"Why it was kept", retained_words(session.retained_reason)},
              {"Next check", readable(session.cleanup_next_attempt_at)}
            ])
      })
    ]
  end

  defp outcome(%Session{cleanup_status: :blocked} = session, worker) do
    [
      step("maintenance-#{session.id}-blocked", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "current",
        title: "Cleanup blocked",
        href: "/working-copies",
        summary:
          "Cleanup stopped while #{String.downcase(step_words(session.cleanup_blocked_from))} " <>
            "and needs attention." <>
            error_words(session.cleanup_last_error_code) <>
            " The delivered answer is unaffected.",
        tone: :warn,
        details:
          session_details(session, worker) ++
            compact_details([
              {"Stopped while", step_words(session.cleanup_blocked_from)},
              {"Tries", session.cleanup_attempt_count}
            ]) ++ error_details(session)
      })
    ]
  end

  defp outcome(%Session{cleanup_status: status} = session, worker)
       when status in [:close_pending, :plan_pending, :discard_pending] do
    [
      step("maintenance-#{session.id}-pending", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "current",
        title: "Cleanup in progress",
        summary:
          "Ryker is #{String.downcase(step_words(status))}." <>
            retrying(session.cleanup_last_error_code, session.cleanup_next_attempt_at),
        tone: nil,
        details:
          session_details(session, worker) ++
            compact_details([
              {"Step", step_words(status)},
              {"Tries", session.cleanup_attempt_count},
              {"Next try", readable(session.cleanup_next_attempt_at)}
            ]) ++ error_details(session)
      })
    ]
  end

  defp outcome(_session, _worker), do: []

  # Which worker held the session, and the session's identities on both sides.
  defp session_details(session, worker) do
    compact_details([
      {"Repository", session.repository_ref},
      {"Worker", worker_name(worker, session), identifier: is_binary(worker)},
      {"Worker session", session.coop_session_id, identifier: true},
      {"Session in Ryker", session.id, identifier: true},
      {"Session generation", session.generation}
    ])
  end

  defp worker_name(worker, _session) when is_binary(worker), do: worker

  defp worker_name(nil, %Session{coop_session_id: id}) when is_binary(id),
    do: "Ryker's own worker"

  defp worker_name(_worker, _session), do: nil

  # What the removal plan found in the working copy before anything was
  # removed or kept, with the fingerprints that bind the plan to it.
  defp plan_details(%Session{discard_plan: %{"workspace" => workspace} = plan} = session)
       when is_map(workspace) do
    compact_details([
      {"Branch", workspace["branch"]},
      {"Commit", workspace["head"], identifier: true},
      {"Uncommitted changes", if(workspace["dirty"], do: "Yes", else: "None")},
      {"Unpublished commits", unpublished_words(workspace)},
      {"Working copy fingerprint", workspace["status_digest"], identifier: true},
      {"Removal plan", session.discard_plan_fingerprint, identifier: true},
      {"Plan request", session.discard_plan_operation_id || plan["operation_id"],
       identifier: true},
      {"Planned at revision", session.discard_plan_expected_revision || plan["revision"]}
    ])
  end

  defp plan_details(_session), do: []

  defp error_details(%Session{cleanup_last_error_code: nil}), do: []

  defp error_details(session) do
    detail =
      if session.cleanup_last_error_detail,
        do:
          session.cleanup_last_error_detail
          |> InspectionRedactor.artifact(max_bytes: 2_048)
          |> Map.fetch!(:text)

    compact_details([
      {"Error", error_words(session.cleanup_last_error_code) |> String.trim()},
      {"Error code", session.cleanup_last_error_code, identifier: true},
      {"Error detail", detail}
    ])
  end

  defp unpublished_words(%{"unmerged" => true, "accepted_unmerged" => true}),
    do: "Yes, removed because the work was published"

  defp unpublished_words(%{"unmerged" => true}), do: "Yes"
  defp unpublished_words(_workspace), do: "None"

  defp closed_summary(%Session{repository_ref: nil}),
    do:
      "After the request ended, Ryker closed its worker session. No repository working copy was bound to it."

  defp closed_summary(%Session{repository_ref: repository}),
    do:
      "After the request ended, Ryker closed #{repository}'s worker session. Closing it does not remove its working copy."

  defp close_request(%Session{close_expected_revision: nil}), do: nil
  defp close_request(session), do: Custody.close_key(session)

  # What the cleanup receipt proves, by the kind cleanup writes. Only
  # "discarded" is a removal this pass made.
  defp cleanup_outcome("never_bound"),
    do:
      {"Nothing to remove",
       "Ryker never learned a worker session for this request, so it had nothing to close or remove."}

  defp cleanup_outcome("already_discarded"),
    do:
      {"Working copy already gone",
       "The worker reported the working copy was already gone; Ryker saw that, it did not delete it."}

  defp cleanup_outcome("remote_absent"),
    do:
      {"Working copy already gone",
       "The worker no longer knew this session, so there was nothing left to close or remove."}

  defp cleanup_outcome("worker_removed"),
    do:
      {"Working copy left on a removed worker",
       "The worker holding it was removed from Ryker, so Ryker cannot reach it to close or remove it."}

  defp cleanup_outcome(_kind),
    do:
      {"Working copy removed",
       "The temporary working copy was removed. What this page shows about the work is unaffected."}

  # What Ryker checked before it removed a working copy it removed itself.
  defp plan_sentence("discarded", %{"workspace" => %{"unmerged" => true}}),
    do:
      " Before removing it, Ryker checked that it held no uncommitted changes; its unmerged commits went because the work was published."

  defp plan_sentence("discarded", %{"workspace" => %{}}),
    do:
      " Before removing it, Ryker checked that it held no uncommitted changes and no unpublished commits."

  defp plan_sentence(_kind, _plan), do: ""

  defp receipt_words("discarded"), do: "Removed at Ryker's request"
  defp receipt_words("already_discarded"), do: "The worker had already removed it"
  defp receipt_words("remote_absent"), do: "The worker no longer knew the session"
  defp receipt_words("worker_removed"), do: "Its worker was removed from Ryker"
  defp receipt_words("never_bound"), do: "No worker session was ever started for it"
  defp receipt_words(_kind), do: nil

  defp remote_words("discarded"), do: "Removed"
  defp remote_words("absent"), do: "Not found"
  defp remote_words("unreachable"), do: "Unreachable"
  defp remote_words("unknown"), do: "Nothing to report"
  defp remote_words(_state), do: nil

  defp retained_reason("dirty" <> _),
    do: "The working copy was kept: it still holds uncommitted changes."

  defp retained_reason("unmerged" <> _),
    do: "The working copy was kept: it still holds commits that were never published."

  defp retained_reason("unpublished_unmerged"),
    do: "The working copy was kept: it still holds commits that were never published."

  defp retained_reason(nil), do: "The working copy was kept. No reason was recorded."
  defp retained_reason(reason), do: "The working copy was kept: " <> human(reason) <> "."

  defp retained_words("dirty" <> _), do: "Uncommitted changes"
  defp retained_words("unpublished_unmerged"), do: "Commits that were never published"
  defp retained_words("unmerged" <> _), do: "Commits that were never published"
  defp retained_words(nil), do: nil
  defp retained_words(reason), do: capitalize(human(reason))

  # A copy with uncommitted changes is checked again later; one holding
  # unpublished commits stays until the work is published or discarded.
  defp recheck(%Session{
         retained_reason: "dirty" <> _,
         cleanup_next_attempt_at: %DateTime{} = at
       }),
       do: " Ryker checks it again at #{clock(at)}."

  defp recheck(%Session{retained_reason: "unpublished_unmerged"}),
    do: " It stays until the work is published or someone discards it on Working copies."

  defp recheck(_session), do: ""

  defp step_words(:close_pending), do: "Closing the worker session"
  defp step_words(:plan_pending), do: "Checking what is safe to remove"
  defp step_words(:discard_pending), do: "Removing the working copy"
  defp step_words(_step), do: "Cleaning up"

  defp retrying(nil, _next), do: ""

  defp retrying(code, next),
    do: " The last try failed:" <> error_words(code) <> tries_again(next)

  defp tries_again(%DateTime{} = at), do: " It tries again at #{clock(at)}."
  defp tries_again(_next), do: ""

  # The recorded error in words; its code stays in Details.
  defp error_words(nil), do: ""
  defp error_words("coop_error"), do: " The worker could not finish this step."

  defp error_words(code) when code in ~w(coop_unavailable coop_transport_error),
    do: " The worker could not be reached."

  defp error_words("coop_worker_command_timeout"), do: " The worker did not answer in time."

  defp error_words("coop_worker_capacity_unavailable"),
    do: " No worker was free to take the step."

  defp error_words("coop_session_replacement_pending"),
    do: " The worker holding the session was handing it over."

  defp error_words("coop_session_replacement_required"),
    do: " The worker that held the session can no longer take it back."

  defp error_words("retention_worker_unavailable"),
    do: " The worker holding the session was offline."

  defp error_words("coop_protocol_error"),
    do: " The worker's answer was not what Ryker expected, so Ryker changed nothing."

  defp error_words("coop_mutation_response_unresolved"),
    do: " Ryker could not confirm the worker's answer to its request."

  defp error_words("retention_generation_spent"),
    do: " The session changed while Ryker acted on it, so the step starts again."

  defp error_words(_code), do: " It stopped on an unexpected error; Details has its code."

  defp until(%DateTime{} = at), do: " until #{clock(at)}"
  defp until(_at), do: ""

  defp clock(at), do: Calendar.strftime(at, "%H:%M UTC")

  defp readable(nil), do: nil
  defp readable(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M:%S UTC")
end
