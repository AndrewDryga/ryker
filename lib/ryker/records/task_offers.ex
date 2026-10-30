defmodule Ryker.Records.TaskOffers do
  @moduledoc """
  Starts one authorized task in one linked, policy-pinned episode.

  A current authenticated request or a confirmed assignment can start directly.
  An unsolicited proposal waits for its delivered confirmation control. Both
  paths resolve the conversation's writable repository policy before starting.
  """
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Maps
  alias Ryker.Memories
  alias Ryker.Records
  alias Ryker.Records.CardDelivery
  alias Ryker.Records.Record
  alias Ryker.Records.TaskInstruction
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack
  alias Ryker.StateTools
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @fields [:actor_ref, :confirmation_ref, :occurred_at, :policy, :record_ref, :target]
  @policy_fields [:digest, :environment_ref, :name, :repository_context, :repository_ref]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @type confirmation :: %{
          episode: Episodes.Episode.t(),
          record: Record.t(),
          session: Work.Session.t(),
          status: :confirmed | :duplicate
        }

  @doc "Start the work a current authenticated person requested, without a second confirmation."
  def start(binding, %{"kind" => "engineering"} = payload, authorize, offer_ref)
      when is_function(authorize, 2) do
    with {:ok, {candidate, _actor}} <-
           TaskInstruction.fetch(
             binding,
             payload["instruction_ref"],
             payload["assignment_ref"],
             payload["repository"]
           ),
         requester <- if(payload["assignment_ref"], do: {:assignment, candidate}, else: candidate),
         {:ok, placement} <- authorize.(requester, payload["repository"]),
         {:ok, placement} <- policy(placement) do
      Repo.transaction(fn ->
        start_in_transaction(binding, payload, offer_ref, candidate, placement)
      end)
    end
  end

  def start(_binding, _payload, _authorize, _offer_ref),
    do: {:error, :task_instruction_not_authorized}

  defp start_in_transaction(binding, payload, offer_ref, candidate, placement) do
    with :ok <- Memories.lock_answer_source_in_transaction(candidate),
         :ok <- TaskInstruction.lock_assignment(payload["assignment_ref"]),
         {:ok, current} <- StateTools.Binding.fetch_and_lock_current_with_episode(binding),
         true <- is_nil(current.session.workspace_task),
         {:ok, {entry, actor}} <-
           TaskInstruction.fetch(
             current,
             payload["instruction_ref"],
             payload["assignment_ref"],
             payload["repository"]
           ),
         true <- Ingress.Inbox.Entry.same_source?(entry, candidate),
         :ok <-
           Slack.ChannelFence.authorize_in_transaction(
             entry.destination_transport,
             entry.destination_conversation_ref
           ),
         {:ok, record} <- fetch_or_create_task(current, payload, offer_ref) do
      attributes = %{
        actor_ref: actor,
        confirmation_ref: payload["instruction_ref"],
        occurred_at: Repo.now!(),
        policy: placement,
        target: %{
          thread_ref: entry.destination_thread_ref,
          message_ref: entry.source_item_ref
        }
      }

      result = start_record(record, current.episode, attributes)

      :ok = Slack.TaskCards.ensure_started(result.record, result.episode)

      %{
        "kind" => "task_offer",
        "record_ref" => result.record.ref,
        "status" => "started",
        "continuation" => nil
      }
    else
      false -> Repo.rollback(:task_instruction_not_authorized)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp start_record(%Record{status: :open} = record, episode, attributes),
    do: create_episode(record, episode, attributes)

  defp start_record(%Record{status: :confirmed} = record, _episode, _attributes),
    do: confirmed(record, :duplicate)

  defp start_record(_record, _episode, _attributes), do: Repo.rollback(:task_offer_stale)

  defp requested_task(binding, payload, offer_ref) when is_binary(offer_ref) do
    query =
      offer_ref
      |> Record.Query.by_ref()
      |> Record.Query.by_episode_id(binding.episode.id)
      |> Record.Query.lock_for_update()

    repository = payload["repository"]

    case Repo.fetch(query) do
      {:ok,
       %Record{
         kind: "task_offer",
         status: :open,
         payload: %{"kind" => "engineering", "repository" => ^repository}
       } = record} ->
        {:ok, record}

      _ ->
        {:error, :task_instruction_not_authorized}
    end
  end

  defp requested_task(binding, payload, nil) do
    Records.create(
      binding.state_token,
      StateTools.RecordWriter.operation_id(binding, "request_task", payload),
      "task_offer",
      payload
    )
  end

  defp fetch_or_create_task(binding, payload, offer_ref) do
    case Repo.fetch(
           Record.Query.started_for_instruction(
             binding.episode.id,
             payload["instruction_ref"],
             payload["repository"]
           )
         ) do
      {:ok, record} when is_nil(offer_ref) or record.ref == offer_ref ->
        {:ok, record}

      {:ok, _another_task} ->
        {:error, :task_instruction_not_authorized}

      {:error, :not_found} ->
        requested_task(binding, payload, offer_ref)
    end
  end

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
    end
  end

  defp confirm_locked(attributes) do
    with {:ok, record, source_episode, source_turn} <- fetch_and_lock_offer(attributes.record_ref),
         :ok <- check_delivery(record, source_episode, source_turn, attributes.target) do
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

  defp fetch_and_lock_offer(record_ref) do
    case Records.fetch_and_lock_offer(record_ref, ["task_offer"]) do
      {:error, :not_found} -> {:error, :task_offer_not_found}
      found -> found
    end
  end

  defp check_delivery(record, episode, turn, target) do
    delivery =
      case {record.payload["kind"], episode.destination_transport} do
        {"engineering", "slack"} ->
          with :settled <- turn.status,
               :ok <- Slack.TaskCards.check_offer_delivery(record, target),
               true <- target.conversation_ref == episode.destination_conversation_ref do
            :ok
          else
            false -> {:error, :mismatch}
            {:error, reason} -> {:error, reason}
            _ -> {:error, :not_delivered}
          end

        _ ->
          CardDelivery.check(episode, turn, target)
      end

    case delivery do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :task_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :task_offer_not_delivered}
    end
  end

  defp create_episode(record, source_episode, attributes) do
    episode_id = Repo.generate_id()
    turn_ref = "turn:task:#{Ecto.UUID.generate()}"

    command = %Episodes.Command.AdmitInput{
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
           Work.Custody.pin_task_episode_in_transaction(
             transition.episode.id,
             attributes.policy.name,
             attributes.policy.digest,
             repository_ref,
             workspace_task(record),
             environment_ref: Map.get(attributes.policy, :environment_ref),
             repository_context: Map.get(attributes.policy, :repository_context),
             repository_source: repository_source
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

  # An incident investigation only reads, under a conversation or incident
  # policy, and Coop binds a workspace task only to a session that may change
  # its repository: it refused every local incident opened in Chat
  # (2026-10-09). A task that changes code is the one that has a workspace.
  defp workspace_task(%{payload: %{"kind" => "incident"}}), do: nil

  defp workspace_task(record) do
    payload = record.payload

    %{
      "authority_limits" => payload["authority_limits"],
      "instruction_ref" => payload["instruction_ref"],
      "offer_ref" => record.ref,
      "prompt" => payload["prompt"],
      "source_refs" => payload["source_refs"],
      "success_checks" => payload["success_checks"],
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
    case Work.RepositorySource.parse(source) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :task_offer_repository_source_mismatch}
    end
  end

  # A task changes exactly the repository its confirmed policy places it in:
  # in an environment, any of its repositories, as that repository's working
  # copy with the others mounted read-only. The caller chose the policy for
  # the repository the offer named; a policy placed elsewhere is a mismatch.
  defp task_repository_placement(nil, _policy), do: :ok

  defp task_repository_placement(repository_ref, %{repository_ref: repository_ref}), do: :ok

  defp task_repository_placement(repository_ref, policy)
       when not is_map_key(policy, :repository_ref),
       do: if(is_binary(repository_ref), do: :ok, else: {:error, :task_offer_repository_mismatch})

  defp task_repository_placement(_repository_ref, _policy),
    do: {:error, :task_offer_repository_mismatch}

  defp persist_confirmation(record, episode, attributes) do
    record
    |> Record.Changeset.confirm(%{
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      confirmed_episode_id: episode.id,
      confirmation_ref: attributes.confirmation_ref,
      status: :confirmed
    })
    |> Repo.update()
    |> case do
      {:ok, confirmed} ->
        :ok = Slack.TaskCards.confirm_offer(confirmed)
        Records.broadcast_record_updated(confirmed)
        {:ok, confirmed}

      {:error, changeset} ->
        {:error, {:task_offer_persistence_failed, changeset.errors}}
    end
  end

  defp fetch_latest_session(episode_id),
    do: Repo.fetch(Work.Session.Query.latest_of_episode(episode_id))

  defp confirmed(record, status) do
    with {:ok, %Episodes.Episode{} = episode} <-
           Repo.fetch(Episodes.Episode.Query.by_id(record.confirmed_episode_id)),
         {:ok, %Work.Session{} = session} <- fetch_latest_session(record.confirmed_episode_id) do
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
    if Maps.exact_keys?(attributes, @fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_task_offer_confirmation, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_task_offer_confirmation, :fields}}

  defp policy(%{} = policy) do
    keys = Map.keys(policy)

    if Enum.all?([:digest, :name], &(&1 in keys)) and keys -- @policy_fields == [] do
      with :ok <- reference(policy.name, :policy),
           true <- Crypto.sha256_hex?(policy.digest),
           :ok <- optional_reference(Map.get(policy, :repository_ref), :repository_ref),
           :ok <- environment_ref(Map.get(policy, :environment_ref)),
           :ok <-
             repository_context(
               Map.get(policy, :repository_context),
               Map.get(policy, :repository_ref)
             ) do
        {:ok, policy}
      else
        {:error, reason} -> {:error, reason}
        false -> {:error, {:invalid_task_offer_confirmation, :policy_digest}}
      end
    else
      {:error, {:invalid_task_offer_confirmation, :policy}}
    end
  end

  defp policy(_policy), do: {:error, {:invalid_task_offer_confirmation, :policy}}

  defp environment_ref(nil), do: :ok

  defp environment_ref(value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,63}\z/, value),
      do: :ok,
      else: {:error, {:invalid_task_offer_confirmation, :environment_ref}}
  end

  defp repository_context(value, repository_ref) do
    case Work.RepositoryContext.restore(value, repository_ref) do
      {:ok, _context} -> :ok
      {:error, :invalid} -> {:error, {:invalid_task_offer_confirmation, :repository_context}}
    end
  end

  defp target(%{} = target) do
    if Maps.exact_keys?(target, @target_fields) do
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
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_task_offer_confirmation, field}}
  end

  defp utc_datetime(value) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, {:invalid_task_offer_confirmation, :occurred_at}}
    end
  end
end
