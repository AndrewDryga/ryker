defmodule Ryker.Delivery.PlatformActionCustody do
  @moduledoc """
  Durable outbox custody for model-requested, host-authorized platform actions.

  A live Work binding may freeze one immutable action per natural host slot.
  Provider workers see only the already-bound route and document. Exact retries
  return the same action; conflicting reuse of a slot is rejected.

  Each action queued, claimed, retried, blocked or delivered is announced after
  the outermost commit (`subscribe_platform_actions/0`), on its request's and
  its conversation's topics too.

  A turn may make a few Slack or Chat reactions (`set_slack_reaction`) and post
  a few updates into its own conversation (`post_slack_update`): at most three
  of each, numbered in the turn (`reaction:1` to `reaction:3`, `update:1` to
  `update:3`). Each is sent only after every earlier one of its kind in the
  turn is delivered, so they arrive in the order the model asked for them.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{PlatformAction, Request}
  alias Ryker.Episodes
  alias Ryker.Lease
  alias Ryker.Maps
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work

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
  @tools [:set_slack_reaction, :post_slack_message, :post_slack_update, :set_github_reaction]
  @kinds [:message, :reaction]
  # The actions a turn may take a few of, each in the next numbered slot of
  # its kind. Single digits: the slots order by their text.
  @numbered %{set_slack_reaction: "reaction", post_slack_update: "update"}
  @numbered_tools Map.keys(@numbered)

  @doc "The tools whose actions are sent in the order the model asked for them."
  @spec numbered_tools() :: [atom()]
  def numbered_tools, do: @numbered_tools
  @maximum_per_turn 3

  @type claim :: %{action: PlatformAction.t(), lease_ref: Ecto.UUID.t()}

  @spec enqueue(map(), map() | keyword()) ::
          {:ok, %{action: PlatformAction.t(), status: :created | :duplicate}} | {:error, term()}
  def enqueue(binding, attributes) do
    with {:ok, attributes} <- exact_attributes(attributes),
         :ok <- natural_slot(attributes),
         {:ok, request} <- request_attributes(attributes),
         :ok <- live_binding_shape(binding) do
      Repo.transaction(fn -> enqueue_locked(binding, attributes, request) end)
    end
  end

  # A reaction or an update takes the turn's next numbered place, never a
  # slot the caller names.
  defp natural_slot(%{tool: tool}) when tool in @numbered_tools,
    do: {:error, {:invalid_platform_action, :host_slot}}

  defp natural_slot(_attributes), do: :ok

  @doc """
  Freezes one of the few reactions or updates a live Work turn may make, in
  the turn's next numbered slot of its kind.

  The same call again returns the action already frozen: the latest one on the
  same emoji and message, or with the same words, when it asked for the same
  thing. A reaction taken back and put on again is a new one. Past the turn's
  #{@maximum_per_turn} of a kind the call is refused with
  `:reaction_limit_reached` or `:update_limit_reached`.
  """
  @spec enqueue_in_turn(map(), map() | keyword()) ::
          {:ok, %{action: PlatformAction.t(), status: :created | :duplicate}} | {:error, term()}
  def enqueue_in_turn(binding, attributes) do
    with {:ok, attributes} <- exact_attributes(with_numbered_slot(attributes)),
         :ok <- numbered_kind(attributes),
         {:ok, _request} <- request_attributes(attributes),
         :ok <- live_binding_shape(binding) do
      refused_as_error(Repo.transaction(fn -> enqueue_in_turn_locked(binding, attributes) end))
    end
  end

  # A refusal writes nothing, so it returns rather than rolls back: Chat calls
  # this inside its own transaction, which a rollback would end.
  defp refused_as_error({:ok, {:refused, reason}}), do: {:error, reason}
  defp refused_as_error(result), do: result

  @doc "How many reactions, and how many updates, one Work turn may make."
  @spec maximum_per_turn() :: pos_integer()
  def maximum_per_turn, do: @maximum_per_turn

  defp numbered_kind(%{tool: :set_slack_reaction, kind: :reaction}), do: :ok
  defp numbered_kind(%{tool: :post_slack_update, kind: :message}), do: :ok
  defp numbered_kind(_attributes), do: {:error, {:invalid_platform_action, :kind}}

  # A placeholder until the turn's next place is known under its lock.
  defp with_numbered_slot(attributes) when is_list(attributes),
    do: attributes |> Map.new() |> with_numbered_slot()

  defp with_numbered_slot(%{} = attributes), do: Map.put(attributes, :host_slot, "numbered")
  defp with_numbered_slot(attributes), do: attributes

  @doc false
  @spec enqueue_confirmed_record_in_transaction(Records.Record.t(), map() | keyword()) ::
          {:ok, %{action: PlatformAction.t(), status: :created | :duplicate}} | {:error, term()}
  def enqueue_confirmed_record_in_transaction(%Records.Record{} = record, attributes) do
    with true <- Repo.in_transaction?(),
         true <- record.kind == "slack_post_offer" and record.status == :open,
         {:ok, attributes} <- exact_attributes(attributes),
         {:ok, request} <- request_attributes(attributes) do
      {:ok, enqueue_for_ids(record.episode_id, record.turn_id, attributes, request)}
    else
      false -> {:error, :platform_action_not_authorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue_confirmed_record_in_transaction(_record, _attributes),
    do: {:error, :platform_action_not_authorized}

  @doc """
  The earliest moment after `since` at which a pending action becomes
  claimable by the clock alone: its retry's backoff ends, or the lease of a
  claim nobody renewed runs out. Nil when no pending action waits on the
  clock; an action waiting its turn waits on a delivery, which is announced.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    since
    |> PlatformAction.Query.select_next_due_after()
    |> Repo.one()
    |> UTCDateTime.earliest()
  end

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
    latest =
      episode_id
      |> PlatformAction.Query.latest_reaction_action(
        conversation_ref,
        source_item_ref,
        emoji_name
      )
      |> Repo.peek()

    latest == "add"
  end

  @spec renew(String.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def renew(action_ref, lease_ref, lease_seconds) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      mutate_claim(action_ref, lease_ref, fn action, now ->
        expiry = Lease.renewed(action.lease_expires_at, now, lease_seconds)
        action |> PlatformAction.Changeset.renew(expiry) |> write!(:renew)
      end)
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
        action
        |> PlatformAction.Changeset.defer(
          DateTime.add(now, retry_seconds, :second),
          error_code,
          error_detail
        )
        |> write!(:defer)
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
        action |> PlatformAction.Changeset.block(error_code, error_detail) |> write!(:block)
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
      {:ok, %PlatformAction{status: :blocked} = action} ->
        action |> PlatformAction.Changeset.retry() |> write!(:retry)

      {:ok, %PlatformAction{status: :pending} = action} ->
        action

      {:ok, %PlatformAction{}} ->
        Repo.rollback(:platform_action_not_retryable)

      {:error, :not_found} ->
        Repo.rollback(:platform_action_not_found)
    end
  end

  @spec confirm_delivery(String.t(), Ecto.UUID.t(), map()) ::
          {:ok, PlatformAction.t()} | {:error, term()}
  def confirm_delivery(action_ref, lease_ref, receipt) do
    with :ok <- reference(action_ref, :action_ref),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         {:ok, receipt} <- Work.DeliveryReceipt.prepare(receipt) do
      fingerprint = Work.DeliveryReceipt.fingerprint(receipt)

      Repo.transaction(fn -> confirm_locked(action_ref, lease_ref, receipt, fingerprint) end)
    end
  end

  @spec validation_records(Ecto.UUID.t(), Ecto.UUID.t() | nil) :: map()
  def validation_records(episode_id, turn_id \\ nil) do
    query =
      episode_id
      |> PlatformAction.Query.by_episode_id()
      |> PlatformAction.Query.ordered_by_oldest()

    query = if turn_id, do: PlatformAction.Query.by_turn_id(query, turn_id), else: query

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
    case Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      {:ok, %Episodes.Episode{} = episode} ->
        episode
        |> Episodes.active_input_events()
        |> Enum.reverse()
        |> Enum.filter(&human_input?/1)
        |> Enum.map(fn event ->
          %{
            "input_ref" => event.dedupe_key,
            "source_item_ref" => get_in(event.payload, ["payload", "source_item_ref"])
          }
        end)

      {:error, :not_found} ->
        []
    end
  end

  defp human_input?(%Episodes.Event{payload: %{"actor_ref" => actor_ref}})
       when is_binary(actor_ref),
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
    {episode, turn} = lock_binding(binding)

    case live_binding(episode, turn, binding, now) do
      :ok -> enqueue_for_ids(episode.id, turn.id, attributes, request)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enqueue_in_turn_locked(binding, attributes) do
    {episode, turn} = lock_binding(binding)

    case live_binding(episode, turn, binding, Repo.now!()) do
      :ok -> next_in_turn(episode, turn, attributes)
      {:error, reason} -> {:refused, reason}
    end
  end

  defp next_in_turn(episode, turn, attributes) do
    earlier =
      turn.id
      |> PlatformAction.Query.by_turn_id()
      |> PlatformAction.Query.by_tool(attributes.tool)
      |> PlatformAction.Query.ordered_by_host_slot()
      |> Repo.all()

    case repeated(earlier, attributes) do
      %PlatformAction{} = same ->
        %{action: same, status: :duplicate}

      nil when length(earlier) >= @maximum_per_turn ->
        {:refused, limit_reached(attributes.tool)}

      nil ->
        slot = "#{Map.fetch!(@numbered, attributes.tool)}:#{length(earlier) + 1}"
        attributes = %{attributes | host_slot: slot}
        {:ok, request} = request_attributes(attributes)
        enqueue_for_ids(episode.id, turn.id, attributes, request)
    end
  end

  # The same call again: the latest action on the same subject, the same emoji
  # on the same message or the same words, asked for exactly the same way.
  defp repeated(earlier, attributes) do
    subject = subject(attributes)

    latest = earlier |> Enum.filter(&(subject(&1) == subject)) |> List.last()
    if latest != nil and intent(latest) == intent(attributes), do: latest
  end

  defp subject(%{kind: :reaction, source_item_ref: item, document: %{"emoji_name" => emoji}}),
    do: {item, emoji}

  defp subject(%{document: document}), do: document

  defp intent(action) do
    Map.take(action, [:conversation_ref, :document, :source_item_ref, :thread_ref, :transport])
  end

  defp limit_reached(:set_slack_reaction), do: :reaction_limit_reached
  defp limit_reached(:post_slack_update), do: :update_limit_reached

  defp lock_binding(binding) do
    episode =
      binding.episode.id
      |> Episodes.Episode.Query.by_id()
      |> Episodes.Episode.Query.lock_for_update()
      |> Repo.peek()

    turn =
      binding.turn.id
      |> Work.Turn.Query.by_id()
      |> Work.Turn.Query.by_episode_id(binding.episode.id)
      |> Work.Turn.Query.lock_for_update()
      |> Repo.peek()

    {episode, turn}
  end

  defp enqueue_for_ids(episode_id, turn_id, attributes, request) do
    fingerprint = CanonicalJSON.digest(request)

    case Repo.fetch(PlatformAction.Query.by_turn_slot(turn_id, attributes.host_slot)) do
      {:ok, %PlatformAction{intent_fingerprint: ^fingerprint} = action} ->
        %{action: action, status: :duplicate}

      {:ok, %PlatformAction{}} ->
        Repo.rollback(:platform_action_slot_conflict)

      {:error, :not_found} ->
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
      id: Repo.generate_id(),
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

    values
    |> PlatformAction.Changeset.insert()
    |> Repo.insert()
    |> unwrap_or_rollback(:insert)
  end

  defp claim_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    case Repo.fetch(PlatformAction.Query.next_claimable(now, @numbered_tools)) do
      {:error, :not_found} ->
        nil

      {:ok, %PlatformAction{} = action} ->
        lease_ref = Ecto.UUID.generate()

        action =
          action
          |> PlatformAction.Changeset.claim(now, lease_seconds, worker_ref, lease_ref)
          |> write!(:claim)

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
      {:ok,
       %PlatformAction{status: :delivered, external_receipt_fingerprint: ^fingerprint} = action} ->
        action

      {:ok, %PlatformAction{status: :delivered}} ->
        Repo.rollback(:platform_action_receipt_conflict)

      {:ok, %PlatformAction{} = action} ->
        with :ok <- current_lease(action, lease_ref, now),
             :ok <- exact_receipt(action, receipt) do
          action
          |> PlatformAction.Changeset.confirm(now, receipt, fingerprint)
          |> write!(:confirm)
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, :not_found} ->
        Repo.rollback(:platform_action_not_found)
    end
  end

  defp leased_action(action_ref, lease_ref, now) do
    case lock_action(action_ref) do
      {:ok, %PlatformAction{status: :pending} = action} ->
        case current_lease(action, lease_ref, now) do
          :ok -> {:ok, action}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %PlatformAction{}} ->
        {:error, :platform_action_not_pending}

      {:error, :not_found} ->
        {:error, :platform_action_not_found}
    end
  end

  defp lock_action(action_ref) do
    action_ref
    |> PlatformAction.Query.by_action_ref()
    |> PlatformAction.Query.lock_for_update()
    |> Repo.fetch()
  end

  defp current_lease(action, lease_ref, now) do
    if Lease.held?(action, lease_ref, now), do: :ok, else: {:error, :platform_action_lease_lost}
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

  defp live_binding_shape(%{episode: %Episodes.Episode{}, turn: %Work.Turn{}}), do: :ok
  defp live_binding_shape(_binding), do: {:error, :platform_action_not_authorized}

  defp live_binding(
         %Episodes.Episode{
           execution_mode: :live,
           state: :working,
           owner_kind: :turn,
           owner_ref: owner_ref
         },
         %Work.Turn{status: :pending, turn_ref: owner_ref} = turn,
         binding,
         now
       ) do
    if Lease.held?(turn, binding.turn.lease_ref, now),
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
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_attributes(),
       else: {:error, {:invalid_platform_action, :fields}}
  end

  defp exact_attributes(%{} = attributes) do
    if Maps.exact_keys?(attributes, @fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_platform_action, :fields}}
  end

  defp exact_attributes(_attributes), do: {:error, {:invalid_platform_action, :fields}}

  defp action_ref(turn_id, host_slot) do
    digest = CanonicalJSON.digest(["platform-action-v1", turn_id, host_slot])
    "platform-action:#{digest}"
  end

  defp write!(changeset, operation),
    do: changeset |> Repo.update() |> unwrap_or_rollback(operation)

  # A renewal only moves the lease's expiry, which no page shows.
  defp unwrap_or_rollback({:ok, value}, :renew), do: value

  defp unwrap_or_rollback({:ok, value}, _operation) do
    broadcast_platform_action_updated(value)
    value
  end

  defp unwrap_or_rollback({:error, changeset}, operation),
    do: Repo.rollback({:platform_action_persistence_failed, operation, changeset.errors})

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_platform_action, field}}
    end
  end

  defp reference(value, field), do: bounded(value, 1_024, field)

  defp bounded(value, maximum, field),
    do: Reference.check(value, field, :invalid_platform_action, maximum)

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_platform_action, field}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to platform action changes: `{:platform_action_updated,
  action_id}` once a Slack message, reaction or GitHub reaction a request asked
  for is queued, claimed, retried, blocked or delivered, and that change has
  committed.
  """
  def subscribe_platform_actions, do: Ryker.PubSub.subscribe(platform_actions_topic())

  def unsubscribe_platform_actions, do: Ryker.PubSub.unsubscribe(platform_actions_topic())

  defp platform_actions_topic, do: "delivery:platform_actions"

  defp broadcast_platform_action_updated(%PlatformAction{id: id} = action) do
    Ryker.Episodes.broadcast_episode_updated(action.episode_id)
    Ryker.Episodes.broadcast_conversation_updated(action.transport, action.conversation_ref)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(platform_actions_topic(), {:platform_action_updated, id})
    end)
  end
end
