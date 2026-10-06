defmodule Ryker.Publication.Followups.Start do
  @moduledoc """
  What starts a follow-up: a publication going out arms one, or rearms it for
  the head it just published, recovery from a stale head or a conflict rearms
  it, and a person's check request or a GitHub webhook about its pull request
  makes the next poll due now.

  Ryker only checks the pull requests it opened, each on its own ten-minute
  timer while it is open (`Followups.Polls`), and never scans a repository. A
  webhook only makes that one check due now, for an open pull request this
  publication recorded, and never for a head other than the one it recorded.
  """

  import Ecto.Query

  alias Ryker.Publication.{Custody, Followup, FollowupChangeset, Publication}
  alias Ryker.Publication.Followups.Store
  alias Ryker.Repo

  @default_deadline_seconds 30 * 24 * 60 * 60

  def arm_published_in_transaction(%Publication{status: :published} = publication, now) do
    attributes = %{
      deadline_at: DateTime.add(now, @default_deadline_seconds, :second),
      episode_id: publication.episode_id,
      id: Ecto.UUID.generate(),
      last_event_key: "baseline",
      next_poll_at: now,
      publication_id: publication.id
    }

    case Repo.one(from(followup in Followup, where: followup.publication_id == ^publication.id)) do
      # Each generation publishes a new head, often to the same pull request,
      # and its checks are its own. The follow-up kept the previous head's
      # check state, so a new head failing the way the old one did woke
      # nothing (2026-10-04 review).
      %Followup{} = followup ->
        reset_followup!(followup, publication, now)

      nil ->
        case Repo.insert(FollowupChangeset.insert(attributes)) do
          {:ok, %Followup{} = followup} ->
            Custody.broadcast_publication_updated(publication)
            followup

          {:error, changeset} ->
            Repo.rollback({:publication_followup_persistence_failed, changeset.errors})
        end
    end
  end

  def arm_published_in_transaction(_publication, _now),
    do: Repo.rollback(:publication_not_delivered)

  def rearm_stale_in_transaction(%Publication{} = publication, now) do
    case Repo.one(
           from(followup in Followup,
             where: followup.publication_id == ^publication.id,
             lock: "FOR UPDATE"
           )
         ) do
      %Followup{pr_state: :stale} = followup ->
        _followup = reset_followup!(followup, publication, now)
        :ok

      %Followup{} ->
        {:error, :publication_recovery_not_stale}

      nil ->
        {:error, :publication_followup_not_found}
    end
  end

  def rearm_conflict_in_transaction(%Publication{} = publication, now) do
    case Repo.one(
           from(followup in Followup,
             where: followup.publication_id == ^publication.id,
             lock: "FOR UPDATE"
           )
         ) do
      %Followup{} = followup ->
        _followup = reset_followup!(followup, publication, now)
        :ok

      nil when is_nil(publication.publication_receipt) ->
        :ok

      nil ->
        {:error, :publication_followup_not_found}
    end
  end

  def nudge_github_event(repository, event_name, delivery_ref, payload)
      when is_binary(repository) and is_binary(event_name) and is_binary(delivery_ref) and
             is_map(payload) do
    with true <- event_name in ~w(check_run check_suite pull_request workflow_run),
         {:ok, number, head_sha} <- github_event_identity(event_name, payload) do
      states = tracked_states(event_name, payload)
      Store.transaction(fn -> nudge_github_locked(repository, number, head_sha, states) end)
    else
      false -> {:ok, :ignored}
      {:error, _reason} -> {:ok, :ignored}
    end
  end

  def nudge_github_event(_repository, _event_name, _delivery_ref, _payload), do: {:ok, :ignored}

  # --- arming ---------------------------------------------------------------

  defp reset_followup!(followup, publication, now) do
    Store.update_followup!(
      followup,
      %{
        checks_failed: 0,
        checks_passed: 0,
        checks_state: :unknown,
        checks_total: 0,
        checks_url: nil,
        deadline_at: DateTime.add(now, @default_deadline_seconds, :second),
        failure_count: 0,
        last_error: nil,
        last_event_key: "baseline:#{String.slice(publication.commit_sha || "pending", 0, 64)}",
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        merge_sha: nil,
        merged_at: nil,
        next_poll_at: now,
        pr_state: :open,
        verification_event_ref: nil,
        verification_sequence: nil,
        verification_turn_ref: nil,
        verified_at: nil
      },
      now
    )
  end

  # --- a GitHub webhook -----------------------------------------------------

  # A closed pull request was checked no more, so one a person reopened was
  # never tracked again (2026-10-04 review). GitHub announces the reopen with
  # the pull request open, and that makes its check due; the check finds it
  # open and resumes the timer.
  defp tracked_states("pull_request", %{"pull_request" => %{"state" => "open"}}),
    do: [:open, :closed]

  defp tracked_states(_event_name, _payload), do: [:open]

  defp nudge_github_locked(repository, number, head_sha, states) do
    now = Repo.now!()

    query =
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        where:
          publication.status == :published and publication.github_repository == ^repository and
            publication.pull_request_number == ^number and followup.pr_state in ^states,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil ->
        :ignored

      followup ->
        publication = Repo.get!(Publication, followup.publication_id)

        if is_nil(head_sha) or head_sha == publication.commit_sha do
          Store.update_followup!(followup, %{next_poll_at: now}, now)
          :nudged
        else
          :ignored
        end
    end
  end

  defp github_event_identity("pull_request", %{"pull_request" => pull}) do
    github_pull_identity(pull)
  end

  defp github_event_identity(event, payload)
       when event in ~w(check_run check_suite workflow_run) do
    item = payload[event]

    with %{} <- item,
         [%{"number" => number} | _rest] <- item["pull_requests"],
         true <- is_integer(number) and number > 0 do
      {:ok, number, get_in(item, ["head_sha"]) || get_in(item, ["head_commit", "id"])}
    else
      _invalid -> {:error, :identity}
    end
  end

  defp github_event_identity(_event, _payload), do: {:error, :identity}

  defp github_pull_identity(%{"head" => %{"sha" => sha}, "number" => number})
       when is_integer(number) and number > 0 and is_binary(sha),
       do: {:ok, number, sha}

  defp github_pull_identity(_pull), do: {:error, :identity}
end
