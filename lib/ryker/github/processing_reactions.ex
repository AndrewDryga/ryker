defmodule Ryker.GitHub.ProcessingReactions do
  @moduledoc """
  Projects active GitHub comments into durable, temporary App-owned eyes.

  A claim records uncertainty before either write. If a receipt is lost,
  repeating GitHub's idempotent add recovers the App reaction ID or restores
  presence after an uncertain delete. Desired changes never release an in-flight lease; its receipt
  records what actually happened without overwriting the newer desired state.
  Settled absent rows are deleted; outstanding cleanup has no age cutoff.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Backoff
  alias Ryker.Delivery
  alias Ryker.ErrorDetail
  alias Ryker.GitHub.{CommentActivity, ProcessingReaction}
  alias Ryker.Lease
  alias Ryker.Repo

  @lease_seconds 180

  def active_targets(name, repository_id) do
    entries = name |> CommentActivity.Query.pending_entries(repository_id) |> Repo.all()
    origins = name |> CommentActivity.Query.active_origins(repository_id) |> Repo.all()
    feedback = name |> CommentActivity.Query.pending_feedback(repository_id) |> Repo.all()
    (entries ++ origins ++ feedback) |> Enum.uniq() |> Enum.flat_map(&comment_target/1)
  end

  defp comment_target(ref) do
    case String.split(ref || "", ":") do
      ["github", kind, id] when kind in ~w(issue_comment pull_request_review_comment) ->
        comment_id_target(kind, id)

      _invalid ->
        []
    end
  end

  defp comment_id_target(kind, value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> [%{comment_kind: kind, comment_id: id}]
      _invalid -> []
    end
  end

  def reconcile(name, binding, targets) do
    Repo.transaction(fn ->
      AdvisoryLock.hold!("github-processing:#{name}")

      reactions =
        name
        |> ProcessingReaction.Query.by_binding(binding.repository_id, binding.ryker_actor_id)
        |> ProcessingReaction.Query.lock_for_update()
        |> Repo.all()

      desired = MapSet.new(targets, &{&1.comment_kind, &1.comment_id})
      existing = MapSet.new(reactions, &{&1.comment_kind, &1.comment_id})

      Enum.each(reactions, fn reaction ->
        reconcile_existing(
          reaction,
          MapSet.member?(desired, {reaction.comment_kind, reaction.comment_id})
        )
      end)

      targets
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing, {&1.comment_kind, &1.comment_id}))
      |> Enum.each(fn target ->
        target
        |> Map.merge(%{
          binding: name,
          repository_id: binding.repository_id,
          actor_id: binding.ryker_actor_id
        })
        |> ProcessingReaction.Changeset.insert()
        |> Repo.insert!()
      end)
    end)
  end

  defp reconcile_existing(reaction, wanted) do
    cond do
      not wanted and is_nil(reaction.lease_ref) and is_nil(reaction.reaction_id) and
          not reaction.uncertain ->
        Repo.delete!(reaction)

      wanted != reaction.desired ->
        reaction
        |> ProcessingReaction.Changeset.update(%{
          desired: wanted,
          blocked: false,
          attempt_count: 0,
          next_attempt_at: nil
        })
        |> Repo.update!()

      true ->
        :ok
    end
  end

  def claim_next(name, binding) do
    Repo.transaction(fn ->
      now = Repo.now!()

      reaction =
        name
        |> ProcessingReaction.Query.by_binding(binding.repository_id, binding.ryker_actor_id)
        |> ProcessingReaction.Query.oldest_due_first(now)
        |> Repo.peek()

      if reaction do
        reaction
        |> ProcessingReaction.Changeset.update(%{
          uncertain: true,
          lease_ref: Repo.generate_id(),
          lease_expires_at: DateTime.add(now, @lease_seconds)
        })
        |> Repo.update!()
      end
    end)
  end

  def settle(%ProcessingReaction{} = reaction, result) do
    Repo.transaction(fn ->
      saved_reaction =
        reaction.id
        |> ProcessingReaction.Query.by_id()
        |> ProcessingReaction.Query.lock_for_update()
        |> Repo.peek()

      if saved_reaction && Lease.held?(saved_reaction, reaction.lease_ref, Repo.now!()) do
        settle_locked(saved_reaction, result, reaction.desired)
      else
        Repo.rollback(:github_processing_lease_lost)
      end
    end)
  end

  defp settle_locked(reaction, {:ok, reaction_id}, _claimed_desired) do
    if not reaction.desired and is_nil(reaction_id) do
      Repo.delete!(reaction)
    else
      reaction
      |> ProcessingReaction.Changeset.update(%{
        reaction_id: reaction_id,
        uncertain: false,
        attempt_count: 0,
        next_attempt_at: nil,
        lease_ref: nil,
        lease_expires_at: nil,
        last_error_code: nil,
        last_error_detail: nil
      })
      |> Repo.update!()
    end
  end

  defp settle_locked(reaction, {:error, reason}, claimed_desired) do
    {code, detail} = ErrorDetail.describe(reason, :github_processing_failed)

    {attempts, delay} =
      case Delivery.Retry.rate_limited(reason) do
        {:ok, seconds} ->
          {reaction.attempt_count, (seconds || 60) * 1_000}

        :error ->
          {reaction.attempt_count + 1, retry_delay(reaction.attempt_count, reason)}
      end

    changed = reaction.desired != claimed_desired

    reaction
    |> ProcessingReaction.Changeset.update(%{
      attempt_count: if(changed, do: 0, else: attempts),
      blocked: not changed and reaction.desired and gone?(reason),
      next_attempt_at: if(changed, do: nil, else: DateTime.add(Repo.now!(), delay, :millisecond)),
      lease_ref: nil,
      lease_expires_at: nil,
      last_error_code: code,
      last_error_detail: detail
    })
    |> Repo.update!()
  end

  # GitHub reactions do not expire. Cleanup must not spend a finite budget
  # and leave permanent eyes after a transient outage or permission repair.
  defp retry_delay(_attempt, {:github_api_error, status, _body}) when status in [401, 403, 422],
    do: 900_000

  defp retry_delay(attempt, _reason), do: Backoff.delay(attempt, 1_000, 60_000, 8)

  defp gone?({:github_api_error, status, _body}), do: status in [404, 410]
  defp gone?(_reason), do: false
end
