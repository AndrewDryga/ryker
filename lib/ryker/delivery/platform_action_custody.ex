defmodule Ryker.Delivery.PlatformActionCustody do
  @moduledoc """
  Durable outbox custody for model-requested, host-authorized platform actions.

  A live Work binding may freeze one immutable action per natural host slot.
  Provider workers see only the already-bound route and document. Exact retries
  return the same action; conflicting reuse of a slot is rejected.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{PlatformAction, Request}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.State.Record
  alias Ryker.Work.{DeliveryReceipt, Turn}

  @fields [
    :conversation_ref,
    :document,
    :host_slot,
    :kind,
    :source_item_ref,
    :thread_ref,
    :tool,
    :transport
  ]
  @tools [:set_slack_reaction, :post_slack_message, :set_github_reaction]
  @kinds [:message, :reaction]

  @type claim :: %{action: PlatformAction.t(), lease_ref: Ecto.UUID.t()}

  @spec enqueue(map(), map() | keyword()) ::
          {:ok, %{action: PlatformAction.t(), status: :created | :duplicate}} | {:error, term()}
  def enqueue(binding, attributes) do
    with {:ok, attributes} <- exact_attributes(attributes),
         {:ok, request} <- request_attributes(attributes),
         :ok <- live_binding_shape(binding) do
      Repo.transaction(fn -> enqueue_locked(binding, attributes, request) end)
    end
  end

  @doc false
  @spec enqueue_confirmed_record_in_transaction(Record.t(), map() | keyword()) ::
          {:ok, %{action: PlatformAction.t(), status: :created | :duplicate}} | {:error, term()}
  def enqueue_confirmed_record_in_transaction(%Record{} = record, attributes) do
    with true <- Repo.in_transaction?(),
         true <- record.kind == "slack_post_offer" and record.status == :open,
         {:ok, attributes} <- exact_attributes(attributes),
         {:ok, request} <- request_attributes(attributes) do
      {:ok, enqueue_for_ids(record.episode_id, record.turn_id, attributes, request)}
    else
      false -> {:error, :platform_action_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_confirmed_record_in_transaction(_record, _attributes),
    do: {:error, :platform_action_not_authorized}

  @spec claim_next(String.t(), pos_integer()) :: {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_locked(worker_ref, lease_seconds) end)
    end
  end

  @spec request(PlatformAction.t()) :: {:ok, Request.t()} | {:error, term()}
  def request(%PlatformAction{} = action) do
    Request.new(%{
      conversation_ref: action.conversation_ref,
      document: action.document,
      kind: action.kind,
      ref: action.action_ref,
      source_item_ref: action.source_item_ref,
      thread_ref: action.thread_ref,
      transport: action.transport
    })
  end

  def request(_action), do: {:error, {:invalid_platform_action, :request}}

  @doc """
  Whether the reaction Ryker currently holds on this message is one it added.

  The latest delivered reaction action for the emoji decides: once Ryker has
  taken its own reaction back, a later removal would take a person's.
  """
  @spec delivered_reaction_added?(
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: boolean()
  def delivered_reaction_added?(episode_id, conversation_ref, source_item_ref, emoji_name) do
    Repo.one(
      from(action in PlatformAction,
        where:
          action.episode_id == ^episode_id and action.tool == :set_slack_reaction and
            action.kind == :reaction and action.status == :delivered and
            action.conversation_ref == ^conversation_ref and
            action.source_item_ref == ^source_item_ref and
            fragment("(?::jsonb) ->> 'emoji_name' = ?", action.document, ^emoji_name),
        order_by: [desc: action.delivered_at, desc: action.inserted_at],
        limit: 1,
        select: fragment("(?::jsonb) ->> 'action'", action.document)
      )
    ) == "add"
  end

  @spec renew(String.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def renew(action_ref, lease_ref, lease_seconds) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(action_ref, lease_ref, lease_seconds) end)
    end
  end

  defp renew_locked(action_ref, lease_ref, lease_seconds) do
    now = Repo.now!()

    case leased_action(action_ref, lease_ref, now) do
      {:ok, action} ->
        requested = DateTime.add(now, lease_seconds, :second)
        expiry = later_datetime(action.lease_expires_at, requested)
        update!(action, %{lease_expires_at: expiry}, :renew)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  @spec defer(String.t(), Ecto.UUID.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def defer(action_ref, lease_ref, retry_seconds, error_code, error_detail) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- positive(retry_seconds, :retry_seconds),
         :ok <- bounded(error_code, 128, :error_code),
         :ok <- bounded(error_detail, 4_096, :error_detail) do
      mutate_claim(action_ref, lease_ref, fn action, now ->
        update!(
          action,
          %{
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, retry_seconds, :second)
          },
          :defer
        )
      end)
    end
  end

  @spec block(String.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def block(action_ref, lease_ref, error_code, error_detail) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- bounded(error_code, 128, :error_code),
         :ok <- bounded(error_detail, 4_096, :error_detail) do
      mutate_claim(action_ref, lease_ref, fn action, _now ->
        update!(
          action,
          %{
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: :blocked
          },
          :block
        )
      end)
    end
  end

  @spec retry(String.t()) :: {:ok, PlatformAction.t()} | {:error, term()}
  def retry(action_ref) do
    with :ok <- reference(action_ref, :action_ref) do
      Repo.transaction(fn -> retry_locked(action_ref) end)
    end
  end

  defp retry_locked(action_ref) do
    case lock_action(action_ref) do
      %PlatformAction{status: :blocked} = action ->
        update!(
          action,
          %{
            attempt_count: 0,
            last_error_code: nil,
            last_error_detail: nil,
            next_attempt_at: nil,
            retry_generation: action.retry_generation + 1,
            status: :pending
          },
          :retry
        )

      %PlatformAction{status: :pending} = action ->
        action

      %PlatformAction{} ->
        Repo.rollback(:platform_action_not_retryable)

      nil ->
        Repo.rollback(:platform_action_not_found)
    end
  end

  @spec confirm_delivery(String.t(), Ecto.UUID.t(), map()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def confirm_delivery(action_ref, lease_ref, receipt) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         {:ok, receipt} <- DeliveryReceipt.prepare(receipt) do
      fingerprint = DeliveryReceipt.fingerprint(receipt)

      Repo.transaction(fn -> confirm_locked(action_ref, lease_ref, receipt, fingerprint) end)
    end
  end

  @spec validation_records(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: map()
  def validation_records(episode_id, turn_id \\ nil) do
    query =
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id,
        order_by: [asc: action.inserted_at, asc: action.id]
      )

    query = if turn_id, do: from(action in query, where: action.turn_id == ^turn_id), else: query

    actions = Repo.all(query)
    current_human_inputs = current_human_inputs(episode_id)

    actions
    |> Map.new(fn action ->
      {action.action_ref,
       %{
         "action" => platform_action_operation(action),
         "action_kind" => Atom.to_string(action.kind),
         "continuation" => nil,
         "current_human_inputs" => current_human_inputs,
         "kind" => "platform_action",
         "source_item_ref" => action.source_item_ref,
         "status" => Atom.to_string(action.status),
         "tool" => Atom.to_string(action.tool)
       }}
    end)
  end

  defp platform_action_operation(%PlatformAction{kind: :reaction, document: document}),
    do: Map.fetch!(document, "action")

  defp platform_action_operation(%PlatformAction{}), do: nil

  defp current_human_inputs(episode_id) do
    case Repo.get(Episode, episode_id) do
      %Episode{active_input_refs: active_input_refs} ->
        episode_id
        |> active_input_events(active_input_refs)
        |> Enum.filter(&human_input?/1)
        |> Enum.map(fn event ->
          %{
            "input_ref" => event.dedupe_key,
            "source_item_ref" => get_in(event.payload, ["payload", "source_item_ref"])
          }
        end)

      nil ->
        []
    end
  end

  defp active_input_events(_episode_id, []), do: []

  defp active_input_events(episode_id, active_input_refs) do
    Repo.all(
      from(event in Event,
        where:
          event.episode_id == ^episode_id and event.kind == :input_admitted and
            event.dedupe_key in ^Enum.uniq(active_input_refs),
        order_by: [asc: event.sequence]
      )
    )
  end

  defp human_input?(%Event{payload: %{"actor_ref" => actor_ref}}) when is_binary(actor_ref),
    do: String.contains?(actor_ref, ":user:")

  defp human_input?(_event), do: false

  @spec model_actions(Ecto.UUID.t()) :: [map()]
  def model_actions(episode_id) do
    episode_id
    |> validation_records()
    |> Enum.sort_by(fn {ref, _action} -> ref end)
    |> Enum.map(fn {ref, action} ->
      %{
        "action_ref" => ref,
        "kind" => action["action_kind"],
        "status" => action["status"],
        "tool" => action["tool"]
      }
    end)
  end

  defp enqueue_locked(binding, attributes, request) do
    now = Repo.now!()

    episode =
      Repo.one(
        from(episode in Episode,
          where: episode.id == ^binding.episode.id,
          lock: "FOR UPDATE"
        )
      )

    turn =
      Repo.one(
        from(turn in Turn,
          where: turn.id == ^binding.turn.id and turn.episode_id == ^binding.episode.id,
          lock: "FOR UPDATE"
        )
      )

    case live_binding(episode, turn, binding, now) do
      :ok -> enqueue_for_ids(episode.id, turn.id, attributes, request)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enqueue_for_ids(episode_id, turn_id, attributes, request) do
    fingerprint = CanonicalJSON.digest(request)

    case Repo.get_by(PlatformAction, turn_id: turn_id, host_slot: attributes.host_slot) do
      %PlatformAction{intent_fingerprint: ^fingerprint} = action ->
        %{action: action, status: :duplicate}

      %PlatformAction{} ->
        Repo.rollback(:platform_action_slot_conflict)

      nil ->
        action_ref = action_ref(turn_id, attributes.host_slot)
        action = insert_action!(episode_id, turn_id, action_ref, attributes, fingerprint)
        %{action: action, status: :created}
    end
  end

  defp insert_action!(episode_id, turn_id, action_ref, attributes, fingerprint) do
    values = %{
      action_ref: action_ref,
      attempt_count: 0,
      conversation_ref: attributes.conversation_ref,
      document: attributes.document,
      episode_id: episode_id,
      host_slot: attributes.host_slot,
      id: Ecto.UUID.generate(),
      intent_fingerprint: fingerprint,
      kind: attributes.kind,
      retry_generation: 0,
      source_item_ref: attributes.source_item_ref,
      status: :pending,
      thread_ref: attributes.thread_ref,
      tool: attributes.tool,
      transport: attributes.transport,
      turn_id: turn_id
    }

    %PlatformAction{}
    |> Ecto.Changeset.cast(values, Map.keys(values))
    |> Ecto.Changeset.validate_required(Map.keys(values) -- [:source_item_ref, :thread_ref])
    |> constraints()
    |> Repo.insert()
    |> unwrap_or_rollback(:insert)
  end

  defp claim_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    case Repo.one(
           from(action in PlatformAction,
             where:
               action.status == :pending and
                 (is_nil(action.next_attempt_at) or action.next_attempt_at <= ^now) and
                 (is_nil(action.lease_expires_at) or action.lease_expires_at <= ^now),
             order_by: [asc: action.inserted_at, asc: action.id],
             limit: 1,
             lock: "FOR UPDATE SKIP LOCKED"
           )
         ) do
      nil ->
        nil

      %PlatformAction{} = action ->
        lease_ref = Ecto.UUID.generate()

        action =
          update!(
            action,
            %{
              attempt_count: action.attempt_count + 1,
              last_error_code: nil,
              last_error_detail: nil,
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref,
              next_attempt_at: nil
            },
            :claim
          )

        %{action: action, lease_ref: lease_ref}
    end
  end

  defp mutate_claim(action_ref, lease_ref, callback) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case leased_action(action_ref, lease_ref, now) do
        {:ok, action} -> callback.(action, now)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp confirm_locked(action_ref, lease_ref, receipt, fingerprint) do
    now = Repo.now!()

    case lock_action(action_ref) do
      %PlatformAction{status: :delivered, external_receipt_fingerprint: ^fingerprint} = action ->
        action

      %PlatformAction{status: :delivered} ->
        Repo.rollback(:platform_action_receipt_conflict)

      %PlatformAction{} = action ->
        with :ok <- current_lease(action, lease_ref, now),
             :ok <- exact_receipt(action, receipt) do
          update!(
            action,
            %{
              delivered_at: now,
              external_receipt: receipt,
              external_receipt_fingerprint: fingerprint,
              last_error_code: nil,
              last_error_detail: nil,
              lease_expires_at: nil,
              lease_owner: nil,
              lease_ref: nil,
              next_attempt_at: nil,
              status: :delivered
            },
            :confirm
          )
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      nil ->
        Repo.rollback(:platform_action_not_found)
    end
  end

  defp leased_action(action_ref, lease_ref, now) do
    case lock_action(action_ref) do
      %PlatformAction{status: :pending} = action ->
        case current_lease(action, lease_ref, now) do
          :ok -> {:ok, action}
          {:error, _reason} = error -> error
        end

      %PlatformAction{} ->
        {:error, :platform_action_not_pending}

      nil ->
        {:error, :platform_action_not_found}
    end
  end

  defp lock_action(action_ref) do
    Repo.one(
      from(action in PlatformAction,
        where: action.action_ref == ^action_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp current_lease(action, lease_ref, now) do
    if action.lease_ref == lease_ref and is_binary(action.lease_owner) and
         match?(%DateTime{}, action.lease_expires_at) and
         DateTime.compare(action.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :platform_action_lease_lost}
  end

  defp exact_receipt(action, receipt) do
    message_matches =
      action.kind == :message or receipt["message_ref"] == action.source_item_ref

    if receipt["delivery_ref"] == action.action_ref and
         receipt["transport"] == action.transport and
         receipt["conversation_ref"] == action.conversation_ref and
         receipt["thread_ref"] == action.thread_ref and message_matches,
       do: :ok,
       else: {:error, :platform_action_receipt_mismatch}
  end

  defp live_binding_shape(%{episode: %Episode{}, turn: %Turn{}}), do: :ok
  defp live_binding_shape(_binding), do: {:error, :platform_action_not_authorized}

  defp live_binding(
         %Episode{
           execution_mode: :live,
           state: :working,
           owner_kind: :turn,
           owner_ref: owner_ref
         },
         %Turn{status: :pending, turn_ref: owner_ref} = turn,
         binding,
         now
       ) do
    if turn.lease_ref == binding.turn.lease_ref and is_binary(turn.lease_ref) and
         match?(%DateTime{}, turn.lease_expires_at) and
         DateTime.compare(turn.lease_expires_at, now) == :gt,
       do: :ok,
       else: {:error, :platform_action_not_authorized}
  end

  defp live_binding(_episode, _turn, _binding, _now),
    do: {:error, :platform_action_not_authorized}

  defp request_attributes(attributes) do
    with true <- attributes.tool in @tools and attributes.kind in @kinds,
         {:ok, _request} <-
           Request.new(%{
             conversation_ref: attributes.conversation_ref,
             document: attributes.document,
             kind: attributes.kind,
             ref: "platform-action-validation",
             source_item_ref: attributes.source_item_ref,
             thread_ref: attributes.thread_ref,
             transport: attributes.transport
           }),
         :ok <- reference(attributes.host_slot, :host_slot) do
      {:ok,
       %{
         "conversation_ref" => attributes.conversation_ref,
         "document" => attributes.document,
         "host_slot" => attributes.host_slot,
         "kind" => Atom.to_string(attributes.kind),
         "source_item_ref" => attributes.source_item_ref,
         "thread_ref" => attributes.thread_ref,
         "tool" => Atom.to_string(attributes.tool),
         "transport" => attributes.transport
       }}
    else
      false -> {:error, {:invalid_platform_action, :kind}}
      {:error, _reason} = error -> error
    end
  end

  defp exact_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_attributes(),
       else: {:error, {:invalid_platform_action, :fields}}
  end

  defp exact_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_platform_action, :fields}}
  end

  defp exact_attributes(_attributes), do: {:error, {:invalid_platform_action, :fields}}

  defp action_ref(turn_id, host_slot) do
    digest = CanonicalJSON.digest(["platform-action-v1", turn_id, host_slot])
    "platform-action:#{digest}"
  end

  defp update!(action, attributes, operation) do
    action
    |> Ecto.Changeset.change(attributes)
    |> constraints()
    |> Repo.update()
    |> unwrap_or_rollback(operation)
  end

  defp constraints(changeset) do
    changeset
    |> Ecto.Changeset.check_constraint(:action_ref, name: :platform_actions_identity_valid)
    |> Ecto.Changeset.check_constraint(:document, name: :platform_actions_document_valid)
    |> Ecto.Changeset.check_constraint(:status, name: :platform_actions_custody_valid)
    |> Ecto.Changeset.unique_constraint(:action_ref)
    |> Ecto.Changeset.unique_constraint([:turn_id, :host_slot])
    |> Ecto.Changeset.foreign_key_constraint(:episode_id)
    |> Ecto.Changeset.foreign_key_constraint(:turn_id)
  end

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp unwrap_or_rollback({:ok, value}, _operation), do: value

  defp unwrap_or_rollback({:error, changeset}, operation),
    do: Repo.rollback({:platform_action_persistence_failed, operation, changeset.errors})

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_platform_action, field}}
    end
  end

  defp reference(value, field), do: bounded(value, 1_024, field)

  defp bounded(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         byte_size(value) <= maximum and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_platform_action, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_platform_action, field}}
end
