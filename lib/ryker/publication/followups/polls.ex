defmodule Ryker.Publication.Followups.Polls do
  @moduledoc """
  What a poll records: the pull request's state and checks as GitHub reported
  them for this exact publication, and the lifecycle event each change means.

  A merge, a close, checks turning red or green, a head that moved outside
  this publication, and the hard deadline each become one event, and a
  person's check request is answered with the current state. Only failing
  checks on the reviewed head wake the source task, because only they are its
  own work to finish.

  An open pull request is checked again every ten minutes until it merges,
  closes, goes stale or reaches its deadline, so Ryker keeps tracking it when
  no GitHub webhook reaches it. A webhook or a person's check request makes
  the next check due at once. A check GitHub does not answer is tried again
  after a delay, and the deadline ends those too.

  After a wakeup other than review feedback, the poll waits for the woken turn
  instead of asking GitHub, until that turn accepts a result, ends another way
  or has held the task for an hour. Then the pull request is checked at once,
  so a webhook or check request that came during the wait is not lost.
  """
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.ErrorDetail
  alias Ryker.Publication.Custody
  alias Ryker.Publication.Followups.{Leases, Store}
  alias Ryker.Publication.LifecycleStatus
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Work.Custody, as: WorkCustody

  # How often an open pull request is checked when no webhook arrives. Slow on
  # purpose: each check spends GitHub API calls, for up to 30 days.
  @recheck_seconds 10 * 60
  # Coop stops any turn after an hour, so a woken turn still holding the task
  # by then is stuck or starting over; GitHub checks resume either way.
  @task_wait_seconds 60 * 60
  @far_future ~U[9999-01-01 00:00:00.000000Z]

  def store_poll(publication_ref, lease_ref, status) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         {:ok, status} <- LifecycleStatus.prepare(status) do
      Store.transaction(fn -> store_poll_locked(publication_ref, lease_ref, status) end)
    end
  end

  def defer_poll(publication_ref, lease_ref, delay_seconds, reason) do
    with :ok <- Store.reference(publication_ref, :publication_ref),
         :ok <- Store.reference(lease_ref, :lease_ref),
         :ok <- Store.positive(delay_seconds, :delay_seconds) do
      Store.transaction(fn ->
        defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason)
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

  defp store_poll_locked(publication_ref, lease_ref, status) do
    with {:ok, followup, publication, now} <- Leases.lock_poll(publication_ref, lease_ref),
         :ok <- exact_status(publication, status) do
      cond do
        past_deadline?(followup, now) ->
          expire(
            followup,
            publication,
            status,
            %{
              checks_state: status["checks_state"],
              checks_total: status["checks_total"],
              checks_passed: status["checks_passed"],
              checks_failed: status["checks_failed"],
              checks_url: status["checks_url"]
            },
            now
          )

        status["head_sha"] != publication.commit_sha and not status["merged"] ->
          _publication = mark_stale_publication!(publication, status["head_sha"], now)

          transition_poll(
            followup,
            publication,
            status,
            %{pr_state: :stale},
            {:status, :failed,
             "The pull-request head changed outside this exact reviewed publication. Automatic tracking stopped until a new exact candidate is reviewed."},
            @far_future,
            now
          )

        true ->
          poll_transition(followup, publication, status, now)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A poll GitHub did not answer is due again after the delay. The deadline
  # was checked only after a poll that worked, so a renamed or transferred
  # repository, a removed App or publication turned off polled every two
  # minutes forever (2026-10-04 review).
  defp defer_poll_locked(publication_ref, lease_ref, delay_seconds, reason) do
    case Leases.lock_poll(publication_ref, lease_ref) do
      {:ok, followup, publication, now} ->
        if past_deadline?(followup, now) do
          observation = %{
            "error" => ErrorDetail.detail(reason),
            "head_sha" => publication.commit_sha
          }

          expire(followup, publication, observation, %{}, now)
        else
          Store.update_followup!(
            followup,
            %{
              failure_count: followup.failure_count + 1,
              last_error: ErrorDetail.detail(reason),
              lease_expires_at: nil,
              lease_owner: nil,
              lease_ref: nil,
              next_poll_at: DateTime.add(now, delay_seconds, :second)
            },
            now
          )
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp past_deadline?(followup, now),
    do: followup.pr_state == :open and DateTime.compare(now, followup.deadline_at) != :lt

  defp expire(followup, publication, observation, attributes, now) do
    transition_poll(
      followup,
      publication,
      observation,
      Map.put(attributes, :pr_state, :expired),
      {:deadline, :failed, "Automatic pull-request tracking reached its hard deadline."},
      @far_future,
      now
    )
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
    |> Publication.Changeset.update(%{
      expected_remote_head_sha: observed_head_sha,
      updated_at: now
    })
    |> Repo.update!()
    |> tap(&Custody.broadcast_publication_updated/1)
  end

  defp poll_transition(followup, publication, status, now) do
    pr_state =
      cond do
        status["merged"] -> :merged
        status["state"] == "closed" -> :closed
        true -> :open
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

    transition_poll(
      followup,
      publication,
      status,
      attributes,
      transition,
      next_check(pr_state, now),
      now
    )
  end

  # The deadline is checked first on every poll, so an open pull request past
  # it is marked expired at its next check and then checked no more.
  defp next_check(:open, now), do: DateTime.add(now, @recheck_seconds, :second)
  defp next_check(_pr_state, _now), do: @far_future

  # --- the lifecycle event it means -----------------------------------------

  defp transition(followup, publication, _status, :merged) when followup.pr_state != :merged do
    {:merged, :succeeded,
     "Draft PR ##{publication.pull_request_number} was merged. I'll keep this task linked only to deployment or Terraform signals carrying its exact PR, branch, head SHA, or merge SHA."}
  end

  defp transition(followup, publication, _status, :closed) when followup.pr_state != :closed do
    {:closed, :stopped,
     "Draft PR ##{publication.pull_request_number} was closed without merging. Automatic delivery tracking stopped."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "failing"}, _pr)
       when old != :failing do
    {:checks, :failed,
     "GitHub checks are failing for PR ##{publication.pull_request_number}. Open the PR for the exact failures."}
  end

  defp transition(%{checks_state: old}, publication, %{"checks_state" => "passing"} = status, _pr)
       when old != :passing do
    {:checks, :succeeded,
     "GitHub checks passed for PR ##{publication.pull_request_number} (#{status["checks_passed"]} of #{status["checks_total"]}). It is ready for human review or merge."}
  end

  defp transition(_followup, _publication, _status, _pr_state), do: nil

  # Failing checks on the exact reviewed head are the agent's own work to finish
  # inside the scope the task already granted, so they resume the episode. The
  # hard deadline, a head that moved outside this publication, a close and a
  # merge are not fixable there: they are facts a person owns, and they stay
  # history. The lifecycle key carries the head SHA, so one red run wakes the
  # task once however often it is polled.
  defp correction_wakeup?(:checks, :failed), do: true
  defp correction_wakeup?(_kind, _state), do: false

  defp transition_poll(followup, publication, status, attributes, transition, next_poll_at, now) do
    attributes =
      Map.merge(attributes, %{
        failure_count: 0,
        last_error: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_poll_at: next_poll_at
      })

    {attributes, event} =
      case transition do
        {kind, state, summary} ->
          key =
            Store.lifecycle_key([
              publication.id,
              Atom.to_string(kind),
              Atom.to_string(state),
              status["head_sha"],
              status["merge_sha"] || ""
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

  defp parse_optional_datetime!(nil), do: nil

  defp parse_optional_datetime!(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end

  # --- the wait for a woken task --------------------------------------------

  defp reconcile_verification_locked(publication_ref, lease_ref, interval_seconds) do
    with {:ok, followup, _publication, now} <- Leases.lock_poll(publication_ref, lease_ref),
         true <- verification_pending?(followup) do
      Store.update_followup!(
        followup,
        wait_attributes(followup, woken_turn(followup, now), now, interval_seconds),
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

  # Where the turn the wakeup handed the task to stands: it accepted a result
  # for the wakeup, it is still working on it, or it ended another way. A newer
  # turn took the task (as one does when the wakeup found the task busy), the
  # task was cancelled, the turn was blocked, or it has held the task longer
  # than Coop lets a turn run.
  defp woken_turn(followup, now) do
    cond do
      verification_recorded?(followup) -> :finished
      still_working?(followup, now) -> :working
      true -> :ended
    end
  end

  defp still_working?(followup, now) do
    case Repo.one(Episode.Query.by_id(followup.episode_id)) do
      %Episode{state: :working, owner_kind: :turn, owner_ref: owner} ->
        owner == followup.verification_turn_ref and within_wait?(followup, now) and
          WorkCustody.turn_in_progress?(followup.episode_id, owner)

      _other ->
        false
    end
  end

  # Counted from when the wakeup was admitted into the task.
  defp within_wait?(followup, now) do
    admitted_at =
      followup.episode_id
      |> Event.Query.by_episode_id()
      |> Event.Query.at_sequence(followup.verification_sequence)
      |> Event.Query.select_inserted_at()
      |> Repo.one()

    is_struct(admitted_at, DateTime) and DateTime.diff(now, admitted_at) < @task_wait_seconds
  end

  defp verification_recorded?(followup) do
    followup.episode_id
    |> Event.Query.by_episode_id()
    |> Event.Query.after_sequence(followup.verification_sequence)
    |> Event.Query.accepted_for_turn(followup.verification_turn_ref)
    |> Repo.exists?()
  end

  defp wait_attributes(_followup, :working, now, interval_seconds),
    do: released(%{next_poll_at: DateTime.add(now, interval_seconds, :second)})

  defp wait_attributes(followup, :finished, now, _interval_seconds),
    do: released(%{next_poll_at: after_wait(followup, now), verified_at: now})

  defp wait_attributes(followup, :ended, now, _interval_seconds) do
    released(%{
      next_poll_at: after_wait(followup, now),
      verification_event_ref: nil,
      verification_sequence: nil,
      verification_turn_ref: nil
    })
  end

  defp released(attributes),
    do: Map.merge(attributes, %{lease_expires_at: nil, lease_owner: nil, lease_ref: nil})

  # GitHub was not asked during the wait, so an open pull request is checked at
  # once: a webhook that came meanwhile gets its check, and the timer resumes
  # from there.
  defp after_wait(followup, now) do
    if followup.pr_state == :open, do: now, else: @far_future
  end
end
