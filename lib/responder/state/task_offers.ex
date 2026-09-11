defmodule Responder.State.TaskOffers do
  @moduledoc """
  Confirms one delivered task offer into one linked, policy-pinned episode.

  The model may propose the inert record. Only this host transition can turn it
  into work, after the platform adapter has authenticated the actor and supplied
  the exact message that carried the control.
  """

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode}
  alias Responder.Repo
  alias Responder.State.{Record, RecordChangeset}
  alias Responder.Work.{Custody, RepositoryContext, RepositorySource, Session, Turn}

  @fields [:actor_ref, :confirmation_ref, :occurred_at, :policy, :record_ref, :target]
  @policy_fields [:digest, :name, :repository_context, :repository_ref]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @type confirmation :: %{
          episode: Episode.t(),
          record: Record.t(),
          session: Session.t(),
          status: :confirmed | :duplicate
        }

  @spec confirm(keyword() | map()) :: {:ok, confirmation()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, policy} <- policy(attributes.policy),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        confirm_locked(%{attributes | occurred_at: occurred_at, policy: policy, target: target})
      end)
      |> transaction_result()
    end
  end

  defp confirm_locked(attributes) do
    with {:ok, record, source_episode, source_turn} <- lock_offer(attributes.record_ref),
         :ok <- delivered_from?(source_episode, source_turn, attributes.target) do
      case record.status do
        :confirmed ->
          confirmed(record, :duplicate)

        :open ->
          create_episode(record, source_episode, attributes)

        _stale ->
          Repo.rollback(:task_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "task_offer",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :task_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp delivered_from?(episode, %Turn{status: :settled, external_receipt: receipt}, target)
       when is_map(receipt) do
    expected = %{
      conversation_ref: episode.destination_conversation_ref,
      message_ref: receipt["message_ref"],
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

    receipt_matches =
      receipt["conversation_ref"] == episode.destination_conversation_ref and
        receipt["thread_ref"] == episode.destination_thread_ref and
        receipt["transport"] == episode.destination_transport

    if receipt_matches and expected == target,
      do: :ok,
      else: {:error, :task_offer_delivery_mismatch}
  end

  defp delivered_from?(_episode, _turn, _target), do: {:error, :task_offer_not_delivered}

  defp create_episode(record, source_episode, attributes) do
    episode_id = Ecto.UUID.generate()
    turn_ref = "turn:task:#{Ecto.UUID.generate()}"

    command = %Command.AdmitInput{
      actor_ref: attributes.actor_ref,
      destination: %{
        conversation_ref: source_episode.destination_conversation_ref,
        thread_ref: attributes.target.thread_ref || attributes.target.message_ref,
        transport: source_episode.destination_transport
      },
      episode_id: episode_id,
      episode_key: "task-offer:#{record.ref}",
      linked_episode_id: source_episode.id,
      native_input_id: "task-confirmation:#{record.ref}",
      occurred_at: attributes.occurred_at,
      payload: %{
        "confirmed_by" => attributes.actor_ref,
        "record_ref" => record.ref,
        "task" => record.payload
      },
      revision: 1,
      turn_ref: turn_ref
    }

    repository_ref = Map.get(attributes.policy, :repository_ref, record.payload["repository"])

    with :ok <- task_repository_placement(record.payload["repository"], attributes.policy),
         {:ok, repository_source} <-
           task_repository_source(record.payload["repository_source"], repository_ref),
         {:ok, [transition]} <- Episodes.apply_batch_in_transaction([command]),
         {:ok, session} <-
           Custody.pin_task_episode_in_transaction(
             transition.episode.id,
             attributes.policy.name,
             attributes.policy.digest,
             repository_ref,
             Map.get(attributes.policy, :repository_context),
             workspace_task(record),
             repository_source
           ),
         {:ok, record} <- persist_confirmation(record, transition.episode, attributes) do
      %{
        episode: transition.episode,
        record: record,
        session: session,
        status: :confirmed
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp workspace_task(record) do
    payload = record.payload

    %{
      "authority_limits" => Map.get(payload, "authority_limits", []),
      "instruction_ref" => Map.get(payload, "instruction_ref", ""),
      "offer_ref" => record.ref,
      "prompt" => payload["prompt"],
      "source_refs" => Map.get(payload, "source_refs", []),
      "success_checks" =>
        Map.get(payload, "success_checks", [
          "Complete the confirmed task and run focused validation."
        ]),
      "title" => payload["title"]
    }
  end

  # The offer carries the worker's exact selector; confirmation re-validates it
  # against the frozen union and against the repository the task was placed in.
  # It becomes the new linked session's immutable source, never a rebind of the
  # session that proposed it.
  defp task_repository_source(nil, _repository_ref), do: {:ok, nil}

  defp task_repository_source(_source, nil),
    do: {:error, :task_offer_repository_source_mismatch}

  defp task_repository_source(source, _repository_ref) do
    case RepositorySource.parse(source) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :task_offer_repository_source_mismatch}
    end
  end

  defp task_repository_placement(nil, _policy), do: :ok

  defp task_repository_placement(
         context_ref,
         %{
           repository_context: %{"context_ref" => context_ref},
           repository_ref: repository_ref
         }
       )
       when is_binary(repository_ref),
       do: :ok

  defp task_repository_placement(repository_ref, %{repository_ref: repository_ref}), do: :ok

  defp task_repository_placement(repository_ref, policy)
       when not is_map_key(policy, :repository_ref),
       do: if(is_binary(repository_ref), do: :ok, else: {:error, :task_offer_repository_mismatch})

  defp task_repository_placement(_repository_ref, _policy),
    do: {:error, :task_offer_repository_mismatch}

  defp persist_confirmation(record, episode, attributes) do
    record
    |> RecordChangeset.confirm(%{
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      confirmed_episode_id: episode.id,
      confirmation_ref: attributes.confirmation_ref,
      status: :confirmed
    })
    |> Repo.update()
    |> case do
      {:ok, confirmed} -> {:ok, confirmed}
      {:error, changeset} -> {:error, {:task_offer_persistence_failed, changeset.errors}}
    end
  end

  defp confirmed(record, status) do
    with %Episode{} = episode <- Repo.get(Episode, record.confirmed_episode_id),
         %Session{} = session <-
           Repo.one(
             from(session in Session,
               where: session.episode_id == ^record.confirmed_episode_id,
               order_by: [desc: session.generation],
               limit: 1
             )
           ) do
      %{episode: episode, record: record, session: session, status: status}
    else
      _missing -> Repo.rollback(:task_offer_confirmation_incomplete)
    end
  end

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> attributes()
    else
      {:error, {:invalid_task_offer_confirmation, :fields}}
    end
  end

  defp attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_task_offer_confirmation, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_task_offer_confirmation, :fields}}

  defp policy(%{} = policy) do
    keys = Map.keys(policy)

    if Enum.all?([:digest, :name], &(&1 in keys)) and keys -- @policy_fields == [] do
      with :ok <- reference(policy.name, :policy),
           true <- is_binary(policy.digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, policy.digest),
           :ok <- optional_reference(Map.get(policy, :repository_ref), :repository_ref),
           :ok <-
             repository_context(
               Map.get(policy, :repository_context),
               Map.get(policy, :repository_ref)
             ) do
        {:ok, policy}
      else
        {:error, _reason} = error -> error
        false -> {:error, {:invalid_task_offer_confirmation, :policy_digest}}
      end
    else
      {:error, {:invalid_task_offer_confirmation, :policy}}
    end
  end

  defp policy(_policy), do: {:error, {:invalid_task_offer_confirmation, :policy}}

  defp repository_context(value, repository_ref) do
    case RepositoryContext.restore(value, repository_ref) do
      {:ok, _context} -> :ok
      {:error, :invalid} -> {:error, {:invalid_task_offer_confirmation, :repository_context}}
    end
  end

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_task_offer_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_task_offer_confirmation, :target}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_task_offer_confirmation, field}}
  end

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_task_offer_confirmation, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_task_offer_confirmation, :occurred_at}}

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
