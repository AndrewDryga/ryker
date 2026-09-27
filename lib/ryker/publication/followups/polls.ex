defmodule Ryker.Publication.Followups.Polls do
  @moduledoc """
  What a poll records: the pull request's state and checks as GitHub reported
  them for this exact publication, and the lifecycle event each change means.

  A merge, a close, checks turning red or green, a head that moved outside
  this publication, and the hard deadline each become one event, and a
  person's check request is answered with the current state. Only failing
  checks on the reviewed head wake the source task, because only they are its
  own work to finish. After a wakeup other than review feedback, the poll
  instead settles whether the woken task has accepted a result for it.
  """

  import Ecto.Query

  alias Ryker.Episodes.Event
  alias Ryker.Publication.Changeset, as: PublicationChangeset
  alias Ryker.Publication.Custody
  alias Ryker.Publication.Followups.{Leases, Store}
  alias Ryker.Publication.LifecycleStatus
  alias Ryker.Repo

  @far_future ~U[9999-01-01 00:00:00.000000Z]

  def store_poll(publication_ref, lease_ref, status, interval_seconds) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(interval_seconds, :interval_seconds),
         {:ok, status} <- LifecycleStatus.prepare(status) do
      Store.transaction(fn ->
        store_poll_locked(publication_ref, lease_ref, status, interval_seconds)
      end)
    end
  end

  def reconcile_verification(publication_ref, lease_ref, interval_seconds) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(interval_seconds, :interval_seconds) do
      Store.transaction(fn ->
        reconcile_verification_locked(publication_ref, lease_ref, interval_seconds)
      end)
    end
  end

  # --- what the poll found --------------------------------------------------

  defp store_poll_locked(publication_ref, lease_ref, status, interval_seconds) do
    with {:ok, followup, publication, now} <- Leases.lock_poll(publication_ref, lease_ref),
         :ok <- exact_status(publication, status) do
      cond do
        DateTime.compare(now, followup.deadline_at) != :lt and followup.pr_state == "open" ->
          transition_poll(
            followup,
            publication,
            status,
            %{
              checks_state: status["checks_state"],
              checks_total: status["checks_total"],
              checks_passed: status["checks_passed"],
              checks_failed: status["checks_failed"],
              checks_url: status["checks_url"],
              pr_state: "expired"
            },
            {"deadline", "failed", "Automatic pull-request tracking reached its hard deadline."},
            @far_future,
            now
          )

        status["head_sha"] != publication.commit_sha and not status["merged"] ->
          _publication = mark_stale_publication!(publication, status["head_sha"], now)

          transition_poll(
            followup,
            publication,
            status,
            %{pr_state: "stale"},
            {"status", "failed",
             "The pull-request head changed outside this exact reviewed publication. Automatic tracking stopped until a new exact candidate is reviewed."},
            @far_future,
            now
          )

        true ->
          poll_transition(followup, publication, status, interval_seconds, now)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exact_status(publication, status) do
    expected_branch = String.replace_prefix(publication.branch_ref || "", "refs/heads/", "")

    if status["number"] == publication.pull_request_number and
         status["url"] == publication.pull_request_url and status["head_ref"] == expected_branch,
       do: :ok,
       else: {:error, :publication_lifecycle_identity_mismatch}
  end

  defp mark_stale_publication!(publication, observed_head_sha, now) do
    publication
    |> PublicationChangeset.update(%{
      expected_remote_head_sha: observed_head_sha,
      updated_at: now
    })
    |> Repo.update!()
    |> tap(&Custody.broadcast_publication_updated/1)
  end

  defp poll_transition(followup, publication, status, _interval_seconds, now) do
    pr_state =
      cond do
        status["merged"] -> "merged"
        status["state"] == "closed" -> "closed"
        true -> "open"
      end

    attributes = %{
      checks_failed: status["checks_failed"],
      checks_passed: status["checks_passed"],
      checks_state: status["checks_state"],
      checks_total: status["checks_total"],
      checks_url: status["checks_url"],
      merge_sha: status["merge_sha"],
      merged_at: parse_optional_datetime!(status["merged_at"]),
      pr_state: pr_state
    }

    transition = transition(followup, publication, status, pr_state)

    transition_poll(followup, publication, status, attributes, transition, @far_future, now)
  end

  # --- the lifecycle event it means -----------------------------------------

  defp transition(followup, publication, _status, "merged") when followup.pr_state != "merged" do
    {"merged", "succeeded",
     "Draft PR ##{publication.pull_request_number} was merged. I’ll keep this task linked only to deployment or Terraform signals carrying its exact PR, branch, head SHA, or merge SHA."}
  end

  defp transition(followup, publication, _status, "closed") when followup.pr_state != "closed" do
    {"closed", "stopped",
     "Draft PR ##{publication.pull_request_number} was closed without merging. Automatic delivery tracking stopped."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "failing"}, _pr)
       when old != "failing" do
    {"checks", "failed",
     "GitHub checks are failing for PR ##{publication.pull_request_number}. Open the PR for the exact failures."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "passing"} = status, _pr)
       when old != "passing" do
    {"checks", "succeeded",
     "GitHub checks passed for PR ##{publication.pull_request_number} (#{status["checks_passed"]} of #{status["checks_total"]}). It is ready for human review or merge."}
  end

  defp transition(%{manual_check_ref: ref}, publication, status, pr_state) when is_binary(ref) do
    {"status", status_state(pr_state, status["checks_state"]),
     current_summary(publication, pr_state, status)}
  end

  defp transition(_followup, _publication, _status, _pr_state), do: nil

  # Failing checks on the exact reviewed head are the agent's own work to finish
  # inside the scope the task already granted, so they resume the episode. The
  # hard deadline, a head that moved outside this publication, a close and a
  # merge are not fixable there: they are facts a person owns, and they stay
  # history. The lifecycle key carries the head SHA, so one red run wakes the
  # task once however often it is polled.
  defp correction_wakeup?("checks", "failed"), do: true
  defp correction_wakeup?(_kind, _state), do: false

  defp transition_poll(followup, publication, status, attributes, transition, next_poll_at, now) do
    attributes =
      Map.merge(attributes, %{
        failure_count: 0,
        last_error: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        manual_check_ref: nil,
        next_poll_at: next_poll_at
      })

    {attributes, event} =
      case transition do
        {kind, state, summary} ->
          key =
            Store.lifecycle_key([
              publication.id,
              kind,
              state,
              status["head_sha"],
              status["merge_sha"] || "",
              followup.manual_check_ref || ""
            ])

          event =
            Store.lifecycle_event(publication, %{
              key: key,
              kind: kind,
              observation: status,
              occurred_at: now,
              source: nil,
              state: state,
              summary: summary,
              wakeup?: correction_wakeup?(kind, state)
            })

          {Map.put(attributes, :last_event_key, key), event}

        nil ->
          {attributes, nil}
      end

    updated = Store.update_followup!(followup, attributes, now)
    if event, do: Store.insert_lifecycle_event!(event)
    updated
  end

  defp status_state("merged", _checks), do: "succeeded"
  defp status_state("closed", _checks), do: "stopped"
  defp status_state(_pr, "failing"), do: "failed"
  defp status_state(_pr, _checks), do: "pending"

  defp current_summary(publication, pr_state, status) do
    checks = status["checks_state"]
    "PR ##{publication.pull_request_number} is #{pr_state}; GitHub checks are #{checks}."
  end

  defp parse_optional_datetime!(nil), do: nil

  defp parse_optional_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  # --- verification ---------------------------------------------------------

  defp reconcile_verification_locked(publication_ref, lease_ref, interval_seconds) do
    with {:ok, followup, _publication, now} <- Leases.lock_poll(publication_ref, lease_ref),
         true <- verification_pending?(followup) do
      verified = verification_recorded?(followup)

      Store.update_followup!(
        followup,
        verification_attributes(verified, now, interval_seconds),
        now
      )
    else
      false -> Repo.rollback(:publication_verification_not_pending)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verification_pending?(followup) do
    is_binary(followup.verification_event_ref) and is_integer(followup.verification_sequence)
  end

  defp verification_recorded?(followup) do
    Repo.exists?(
      from(event in Event,
        where:
          event.episode_id == ^followup.episode_id and
            event.sequence > ^followup.verification_sequence and event.kind == :result_accepted and
            fragment(
              "(?::jsonb ->> 'expected_turn_ref') = ?",
              event.payload,
              ^followup.verification_turn_ref
            )
      )
    )
  end

  defp verification_attributes(verified, now, interval_seconds) do
    %{
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_poll_at:
        if(verified, do: @far_future, else: DateTime.add(now, interval_seconds, :second)),
      verified_at: if(verified, do: now, else: nil)
    }
  end
end
