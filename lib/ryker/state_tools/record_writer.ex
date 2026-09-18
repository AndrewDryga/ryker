defmodule Ryker.StateTools.RecordWriter do
  @moduledoc false

  # The one place a state tool turns its arguments into a ledger record: the
  # host-owned operation identity, the per-tool idempotency slot, and the
  # bounded result the model reads back.

  alias Ryker.CanonicalJSON
  alias Ryker.State.{Record, Records}

  @contract_version "responder-state:v1"

  # Inspection uses the same host identity as creation, not matching prose. A
  # repeated call may refer to an existing citation; this does not name a creator.
  @spec citation_record?(term(), map(), term()) :: boolean()
  def citation_record?(%Record{kind: "evidence"} = record, turn, arguments)
      when is_map(arguments) do
    record.episode_id == turn.episode_id && record.turn_id == turn.id &&
      record.operation_id ==
        operation_id(%{episode: %{id: turn.episode_id}, turn: turn}, "cite_source", arguments) &&
      record.payload["claim_id"] == subject_ref("citation", arguments)
  end

  def citation_record?(_record, _turn, _arguments), do: false

  @spec create_record(map(), String.t(), map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_record(binding, tool, arguments, kind, payload) do
    with {:ok, record} <- create(binding, tool, arguments, kind, payload) do
      {:ok, result(record, record.kind)}
    end
  end

  # The stored kind stays the ledger's; the model reads the public name.
  @spec create_public_record(map(), String.t(), map(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def create_public_record(binding, tool, arguments, kind, payload, public_kind)
      when is_binary(public_kind) do
    with {:ok, record} <- create(binding, tool, arguments, kind, payload) do
      {:ok, result(record, public_kind)}
    end
  end

  @spec operation_id(map(), String.t(), map()) :: String.t()
  def operation_id(binding, tool, arguments) do
    "host:" <>
      CanonicalJSON.digest(%{
        "contract_version" => @contract_version,
        "episode_id" => binding.episode.id,
        "host_slot" => host_slot(tool, arguments),
        "tool" => tool,
        "turn_id" => binding.turn.id
      })
  end

  @spec subject_ref(String.t(), map()) :: String.t()
  def subject_ref(prefix, arguments),
    do: prefix <> ":" <> binary_part(CanonicalJSON.digest(arguments), 0, 32)

  defp create(binding, tool, arguments, kind, payload) do
    options = [parallel_goal_limit: parallel_goal_limit(binding.session)]
    operation_id = operation_id(binding, tool, arguments)

    case {tool, kind} do
      {"wait_for", "event_wait"} ->
        Records.create_reusing_open_source_wait(
          binding.state_token,
          operation_id,
          payload,
          options
        )

      _other ->
        Records.create(binding.state_token, operation_id, kind, payload, options)
    end
  end

  defp result(record, kind) do
    %{
      "continuation" => record.continuation,
      "kind" => kind,
      "record_ref" => record.ref
    }
  end

  defp parallel_goal_limit(%{repository_context: %{"parallel_goal_limit" => limit}})
       when is_integer(limit) and limit in 1..3,
       do: limit

  defp parallel_goal_limit(_session), do: 3

  defp host_slot("request_input", _arguments), do: "question-set"
  defp host_slot("wait_for", _arguments), do: "pending-wait"

  defp host_slot("request_task", arguments),
    do: [
      Map.get(arguments, "kind", "engineering"),
      arguments["repository"],
      arguments["instruction_ref"]
    ]

  defp host_slot("cite_source", arguments),
    do: [arguments["source_ref"], arguments["subject"], arguments["relation"]]

  defp host_slot("propose_memory", arguments),
    do: [arguments["scope"], arguments["kind"], arguments["subject"]]

  defp host_slot("record_feedback", arguments),
    do: [arguments["target_message_ref"], arguments["category"]]

  defp host_slot("validate_final", arguments), do: CanonicalJSON.digest(arguments)
  defp host_slot("propose_automation:" <> index, _arguments), do: index
  defp host_slot(_tool, arguments), do: CanonicalJSON.digest(arguments)
end
