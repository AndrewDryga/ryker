defmodule Ryker.Operator.Actions do
  @moduledoc """
  Durable, idempotent audit custody for privileged local operator actions.

  The caller supplies only bounded identity and payload-free request metadata.
  The protected callback runs in the same PostgreSQL transaction as the audit
  insert, so a lost response can be reconciled by repeating the action ref.

  Each recorded action is announced after the outermost commit
  (`subscribe_actions/0`); what the action changed is announced by the
  context that owns it.
  """

  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Operator.Action
  alias Ryker.Reference
  alias Ryker.Repo

  @fields [:action, :action_ref, :actor_ref, :kind, :request, :resource_ref]

  @spec run(map(), (-> {:ok, %{previous: map(), outcome: map()}} | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def run(attributes, operation) when is_map(attributes) and is_function(operation, 0) do
    with {:ok, attributes} <- attributes(attributes) do
      fingerprint = request_fingerprint(attributes)

      Repo.transaction(fn -> run_locked(attributes, fingerprint, operation) end)
      |> transaction_result()
    end
  end

  def run(_attributes, _operation), do: {:error, {:invalid_operator_action, :arguments}}

  @doc """
  The actor a Slack operator acts as, checked against the saved operator
  membership. Membership is a durable setting, so a disconnected Slack
  integration does not silently revoke it, and a connected one does not grant
  it.
  """
  @spec operator_actor(term()) :: {:ok, String.t()} | {:error, term()}
  def operator_actor(operator) when is_binary(operator) do
    with {:ok, settings} <- Ryker.Settings.fetch() do
      if operator in settings.slack.operators,
        do: {:ok, "slack:user:#{operator}"},
        else: {:error, :configured_slack_operator_required}
    end
  end

  def operator_actor(_operator), do: {:error, :configured_slack_operator_required}

  @spec fetch(String.t()) :: {:ok, Action.t()} | :error
  def fetch(action_ref) do
    with :ok <- Reference.check(action_ref, :action_ref, :invalid_operator_action),
         %Action{} = action <- Repo.one(Action.Query.by_action_ref(action_ref)) do
      {:ok, action}
    else
      _unavailable -> :error
    end
  end

  defp run_locked(attributes, fingerprint, operation) do
    AdvisoryLock.hold!(attributes.action_ref)

    locked =
      attributes.action_ref |> Action.Query.by_action_ref() |> Action.Query.lock_for_update()

    case Repo.one(locked) do
      %Action{request_fingerprint: ^fingerprint} = action ->
        receipt(action, :duplicate)

      %Action{} ->
        Repo.rollback(:operator_action_conflict)

      nil ->
        execute_and_record(attributes, fingerprint, operation)
    end
  end

  defp execute_and_record(attributes, fingerprint, operation) do
    with {:ok, %{outcome: outcome, previous: previous}} <- operation.(),
         :ok <- document(previous, :previous),
         :ok <- document(outcome, :outcome) do
      now = Repo.now!()

      action =
        %{
          action: attributes.action,
          action_ref: attributes.action_ref,
          actor_ref: attributes.actor_ref,
          kind: attributes.kind,
          occurred_at: now,
          outcome: outcome,
          previous: previous,
          request_fingerprint: fingerprint,
          resource_ref: attributes.resource_ref
        }
        |> Action.Changeset.insert()
        |> Repo.insert!()

      broadcast_action_recorded(action.id)
      receipt(action, :recorded)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp receipt(action, status) do
    %{
      action_ref: action.action_ref,
      actor_ref: action.actor_ref,
      outcome: action.outcome,
      status: status
    }
  end

  defp attributes(attributes) do
    with true <- Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
         true <- attributes.action in [:retry, :replay, :update, :discard],
         :ok <- reference(attributes.action_ref, :action_ref),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- Reference.check(attributes.kind, :kind, :invalid_operator_action, 64),
         :ok <- reference(attributes.resource_ref, :resource_ref),
         :ok <- document(attributes.request, :request) do
      {:ok, attributes}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_operator_action, :attributes}}
    end
  end

  defp request_fingerprint(attributes) do
    CanonicalJSON.digest(%{
      "action" => Atom.to_string(attributes.action),
      "actor_ref" => attributes.actor_ref,
      "kind" => attributes.kind,
      "request" => attributes.request,
      "resource_ref" => attributes.resource_ref
    })
  end

  defp document(value, field) when is_map(value) do
    case CanonicalJSON.validate(value, max_bytes: 16_384) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_operator_action, field}}
    end
  end

  defp document(_value, field), do: {:error, {:invalid_operator_action, field}}

  defp reference(value, field), do: Reference.check(value, field, :invalid_operator_action)

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to operator actions: `{:operator_action_recorded,
  action_id}` once a retry, rearm, discard or other privileged operator action
  is recorded, and that change has committed.
  """
  def subscribe_actions, do: Ryker.PubSub.subscribe(actions_topic())

  def unsubscribe_actions, do: Ryker.PubSub.unsubscribe(actions_topic())

  @doc """
  Internal — announces, after the outermost commit, that operator action
  `action_id` was recorded. Working-copy recovery (`Ryker.Operator.Retention`)
  keeps its own audit rows and announces them here too.
  """
  @spec broadcast_action_recorded(Ecto.UUID.t()) :: :ok
  def broadcast_action_recorded(action_id) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(actions_topic(), {:operator_action_recorded, action_id})
    end)
  end

  defp actions_topic, do: "operator:actions"
end
