defmodule Ryker.Operator.Actions do
  @moduledoc """
  Durable, idempotent audit custody for privileged local operator actions.

  The caller supplies only bounded identity and payload-free request metadata.
  The protected callback runs in the same PostgreSQL transaction as the audit
  insert, so a lost response can be reconciled by repeating the action ref.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Operator.Action
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

  @spec fetch(String.t()) :: {:ok, Action.t()} | :error
  def fetch(action_ref) do
    with :ok <- reference(action_ref, :action_ref),
         %Action{} = action <- Repo.get_by(Action, action_ref: action_ref) do
      {:ok, action}
    else
      _unavailable -> :error
    end
  end

  defp run_locked(attributes, fingerprint, operation) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      attributes.action_ref
    ])

    case Repo.one(
           from(action in Action,
             where: action.action_ref == ^attributes.action_ref,
             lock: "FOR UPDATE"
           )
         ) do
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
      now = database_now!()

      action =
        %Action{}
        |> Ecto.Changeset.cast(
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
          },
          [
            :action,
            :action_ref,
            :actor_ref,
            :kind,
            :occurred_at,
            :outcome,
            :previous,
            :request_fingerprint,
            :resource_ref
          ]
        )
        |> Ecto.Changeset.validate_required([
          :action,
          :action_ref,
          :actor_ref,
          :kind,
          :occurred_at,
          :outcome,
          :previous,
          :request_fingerprint,
          :resource_ref
        ])
        |> Ecto.Changeset.validate_length(:action_ref, min: 1, max: 1_024)
        |> Ecto.Changeset.validate_length(:actor_ref, min: 1, max: 1_024)
        |> Ecto.Changeset.validate_length(:kind, min: 1, max: 64)
        |> Ecto.Changeset.validate_length(:resource_ref, min: 1, max: 1_024)
        |> Ecto.Changeset.validate_format(:request_fingerprint, ~r/\A[0-9a-f]{64}\z/)
        |> Ecto.Changeset.unique_constraint(:action_ref)
        |> Ecto.Changeset.check_constraint(:action_ref,
          name: :responder_operator_action_valid
        )
        |> Repo.insert!()

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
         :ok <- reference(attributes.kind, :kind, 64),
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

  defp reference(value, field, maximum \\ 1_024)

  defp reference(value, field, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_operator_action, field}}
  end

  defp reference(_value, field, _maximum), do: {:error, {:invalid_operator_action, field}}

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
