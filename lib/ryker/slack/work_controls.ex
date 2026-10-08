defmodule Ryker.Slack.WorkControls do
  @moduledoc """
  Executes one authenticated control against its exact durable Slack work card.

  The interaction value is only an opaque lookup key. This module reloads the
  card, episode, Work custody, and destination before any transition or network
  request. Copied and stale controls therefore grant no authority.
  """
  alias Ryker.Adapter
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Operator
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Slack.{WorkRecord, WorkTarget}
  alias Ryker.Work

  @control_fields [:actor_ref, :occurred_at, :request_ref, :target, :work_ref]
  @publication_fields @control_fields ++ [:publication_ref]
  @publication_recovery_fields @publication_fields ++ [:expected_generation]
  @record_fields @control_fields ++ [:record_kind]

  @doc """
  Whether a card offers Stop: its episode is working on exactly this turn,
  and the turn has not begun stopping, parking or settling.
  """
  @spec stoppable?(term(), term()) :: boolean()
  def stoppable?(
        %Episodes.Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref},
        %Work.Turn{status: :pending, turn_ref: turn_ref}
      ),
      do: true

  def stoppable?(_episode, _turn), do: false

  @doc "Whether a card offers its diff: the work has a Coop session to read the changes from."
  @spec diff_available?(term()) :: boolean()
  def diff_available?(%Work.Session{coop_session_id: value})
      when is_binary(value) and value != "",
      do: true

  def diff_available?(_session), do: false

  @spec stop(map()) :: {:ok, map()} | {:error, term()}
  def stop(attributes) do
    with {:ok, attributes} <- attributes(attributes, @control_fields),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, turn_ref} <- stoppable_turn(resolved.episode),
         {:ok, result} <-
           Work.Custody.request_stop(
             resolved.episode.id,
             resolved.episode.key,
             turn_ref,
             attributes.request_ref,
             "The operator stopped the current run. Reply in the same thread to continue this work."
           ) do
      {:ok,
       %{
         outcome: if(result.status == :settled, do: :stopped, else: :stopping),
         turn: result.turn,
         work_ref: resolved.work_ref
       }}
    end
  end

  @doc """
  Continue a run an operator stopped, from the exact turn the card showed.

  `expected_recovery` is the fingerprint the card carried, so a stale card
  refuses rather than restarting work that has moved on since.
  """
  @spec resume(map()) :: {:ok, map()} | {:error, term()}
  def resume(%{expected_recovery: fingerprint} = attributes) when is_binary(fingerprint) do
    attributes = Map.delete(attributes, :expected_recovery)

    with {:ok, prepared} <- attributes(attributes, @control_fields),
         {:ok, resolved} <- WorkTarget.resolve(prepared.work_ref, prepared.target),
         {:ok, episode} <- Work.Custody.retry_blocked(resolved.episode.key, fingerprint) do
      {:ok, %{outcome: :resumed, episode: episode, work_ref: resolved.work_ref}}
    end
  end

  def resume(_attributes), do: {:error, :invalid_slack_work_control}

  @spec close(map()) :: {:ok, map()} | {:error, term()}
  def close(attributes) do
    with {:ok, attributes} <- attributes(attributes, @control_fields),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target) do
      close_resolved(resolved, attributes)
    end
  end

  @spec show_record(map(), map()) :: {:ok, map()} | {:error, term()}
  def show_record(attributes, options) when is_map(options) do
    with {:ok, attributes} <- attributes(attributes, @record_fields),
         {:ok, options} <- record_options(options),
         {:ok, resolved} <- WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, document} <-
           options.work_record.build(
             resolved.work_ref,
             attributes.target,
             attributes.record_kind
           ),
         :ok <- show_privately(resolved, attributes.actor_ref, document, options) do
      {:ok,
       %{
         outcome: :shown,
         record_kind: attributes.record_kind,
         work_ref: resolved.work_ref
       }}
    end
  end

  def show_record(_attributes, _options), do: {:error, :invalid_work_control}

  @spec approve_publication(map()) :: {:ok, map()} | {:error, term()}
  def approve_publication(attributes) do
    with {:ok, attributes} <- attributes(attributes, @publication_fields),
         {:ok, %{kind: :task} = resolved} <-
           WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, publication} <-
           approvable_publication(resolved.episode.id, attributes.publication_ref),
         {:ok, target} <- publication_review_target(publication),
         {:ok, approval} <-
           Publication.Custody.approve(%{
             actor_ref: attributes.actor_ref,
             approval_ref: attributes.request_ref,
             occurred_at: attributes.occurred_at,
             publication_ref: attributes.publication_ref,
             target: target
           }) do
      {:ok,
       %{
         outcome: approval.status,
         publication_ref: approval.publication.ref,
         work_ref: resolved.work_ref
       }}
    else
      {:ok, _non_task} -> {:error, :task_publication_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recover_publication(map(), :retry | :update | :discard) ::
          {:ok, map()} | {:error, term()}
  def recover_publication(attributes, action) when action in [:retry, :update, :discard] do
    with {:ok, attributes} <- attributes(attributes, @publication_recovery_fields),
         {:ok, %{kind: :task} = resolved} <-
           WorkTarget.resolve(attributes.work_ref, attributes.target),
         {:ok, publication} <-
           publication(resolved.episode.id, attributes.publication_ref),
         {:ok, receipt} <-
           Operator.Publication.recover(
             publication.ref,
             action,
             attributes.expected_generation,
             actor_ref: attributes.actor_ref,
             action_ref: attributes.request_ref
           ) do
      {:ok,
       %{
         outcome: String.to_existing_atom(receipt.outcome["status"]),
         publication_ref: publication.ref,
         work_ref: resolved.work_ref
       }}
    else
      {:ok, _non_task} -> {:error, :task_publication_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def recover_publication(_attributes, _action), do: {:error, :invalid_work_control}

  defp close_resolved(%{episode: %{state: state}} = resolved, _attributes)
       when state in [:complete, :cancelled] do
    {:ok, %{outcome: :closed, work_ref: resolved.work_ref}}
  end

  defp close_resolved(%{episode: %{state: :working, owner_kind: :delivery}}, _attributes),
    do: {:error, :work_delivery_must_settle}

  defp close_resolved(
         %{episode: %{state: :working, owner_kind: :turn, owner_ref: turn_ref} = episode} =
           resolved,
         attributes
       ) do
    with {:ok, result} <-
           Work.Custody.request_cancel(
             episode.id,
             episode.key,
             turn_ref,
             attributes.request_ref,
             "Closed by #{attributes.actor_ref} from the exact Slack work card."
           ) do
      {:ok,
       %{
         outcome: if(result.status == :settled, do: :closed, else: :closing),
         work_ref: resolved.work_ref
       }}
    end
  end

  defp close_resolved(
         %{episode: %{state: state, owner_kind: owner_kind, owner_ref: owner_ref} = episode} =
           resolved,
         attributes
       )
       when state in [:waiting_for_input, :waiting_for_event] and owner_kind in [:input, :event] do
    command = %Episodes.Command.CancelEpisode{
      cancel_ref: attributes.request_ref,
      episode_key: episode.key,
      expected_owner: %{kind: owner_kind, ref: owner_ref},
      occurred_at: attributes.occurred_at,
      reason: "Closed by #{attributes.actor_ref} from the exact Slack work card."
    }

    with {:ok, _transition} <- Episodes.apply(command) do
      {:ok, %{outcome: :closed, work_ref: resolved.work_ref}}
    end
  end

  defp close_resolved(_resolved, _attributes), do: {:error, :work_control_stale}

  # The card offered Stop by `stoppable?/2`; pressing it asks the same of the
  # turn as it is now.
  defp stoppable_turn(
         %{state: :working, owner_kind: :turn, owner_ref: turn_ref, id: id} = episode
       ) do
    turn =
      id
      |> Work.Turn.Query.by_episode_id()
      |> Work.Turn.Query.by_turn_ref(turn_ref)
      |> Repo.peek()

    if stoppable?(episode, turn),
      do: {:ok, turn_ref},
      else: {:error, :work_control_stale}
  end

  defp stoppable_turn(_episode), do: {:error, :work_control_stale}

  # A reviewed candidate publishes on its ordinary path; a blocked one is
  # offered only when the separate draft-shareability verdict says its exact
  # snapshot is safe. Custody re-decides both; this is the card's own fence.
  defp approvable_publication(episode_id, publication_ref) do
    case episode_publication(episode_id, publication_ref) do
      {:ok, %Publication.Publication{status: :reviewed} = publication} ->
        {:ok, publication}

      {:ok, %Publication.Publication{status: :blocked} = publication} ->
        if Publication.Review.draft_shareable?(publication.review_document),
          do: {:ok, publication},
          else: {:error, :task_publication_not_ready}

      {:ok, %Publication.Publication{}} ->
        {:error, :task_publication_not_ready}

      {:error, :not_found} ->
        {:error, :task_publication_mismatch}
    end
  end

  defp publication(episode_id, publication_ref) do
    case episode_publication(episode_id, publication_ref) do
      {:ok, %Publication.Publication{} = publication} -> {:ok, publication}
      {:error, :not_found} -> {:error, :task_publication_mismatch}
    end
  end

  defp episode_publication(episode_id, publication_ref) do
    episode_id
    |> Publication.Publication.Query.by_episode_id()
    |> Publication.Publication.Query.by_ref(publication_ref)
    |> Repo.fetch()
  end

  defp publication_review_target(%Publication.Publication{review_delivery_receipt: receipt})
       when is_map(receipt),
       do: publication_target(receipt)

  defp publication_review_target(_publication), do: {:error, :task_publication_not_ready}

  defp publication_target(receipt) do
    target = %{
      conversation_ref: receipt["conversation_ref"],
      message_ref: receipt["message_ref"],
      thread_ref: receipt["thread_ref"],
      transport: receipt["transport"]
    }

    if Enum.all?([target.conversation_ref, target.message_ref, target.transport], &is_binary/1),
      do: {:ok, target},
      else: {:error, :task_publication_not_ready}
  end

  # Only the person who asked sees a record, in the task's thread (Andrew, 2026-10-01: "should be
  # visible just for me not posted to thread and spam everyone").
  defp show_privately(resolved, "slack:user:" <> user, %{"message" => text}, options) do
    options.slack_api.post_ephemeral(
      options.slack_client,
      resolved.channel_ref,
      user,
      resolved.output_thread_ref,
      text
    )
  end

  defp show_privately(_resolved, _actor_ref, _document, _options),
    do: {:error, :work_record_not_available}

  defp attributes(%{} = attributes, fields) do
    valid =
      Enum.all?([
        Maps.exact_keys?(attributes, fields),
        present_binary?(Map.get(attributes, :actor_ref)),
        present_binary?(Map.get(attributes, :request_ref)),
        present_binary?(Map.get(attributes, :work_ref)),
        match?(%DateTime{}, Map.get(attributes, :occurred_at)),
        is_map(Map.get(attributes, :target)),
        valid_expected_generation?(attributes, fields),
        valid_publication_ref?(attributes, fields),
        valid_record_kind?(attributes, fields)
      ])

    if valid do
      {:ok, attributes}
    else
      {:error, :invalid_work_control}
    end
  end

  defp attributes(_attributes, _fields), do: {:error, :invalid_work_control}

  defp present_binary?(value), do: is_binary(value) and value != ""

  defp valid_expected_generation?(attributes, fields) do
    :expected_generation not in fields or
      (is_integer(Map.get(attributes, :expected_generation)) and
         Map.get(attributes, :expected_generation) > 0)
  end

  defp valid_publication_ref?(attributes, fields) do
    :publication_ref not in fields or
      reference?(
        Map.get(attributes, :publication_ref),
        ~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/
      )
  end

  defp valid_record_kind?(attributes, fields) do
    :record_kind not in fields or
      Map.get(attributes, :record_kind) in [
        :timeline,
        :evidence,
        :handoff,
        :recovery,
        :postmortem
      ]
  end

  defp reference?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp record_options(%{} = options) do
    options = Map.put_new(options, :work_record, WorkRecord)
    required = [:slack_api, :slack_client, :work_record]

    if Maps.exact_keys?(options, required) and
         Adapter.implements?(options.work_record, build: 3) and slack_api?(options.slack_api) do
      {:ok, options}
    else
      {:error, :invalid_work_control_options}
    end
  end

  defp slack_api?(api) do
    Adapter.implements?(api, find_message: 4, post_message: 5, update_message: 5)
  end
end
