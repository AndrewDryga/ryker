defmodule Responder.StateTools.Tools do
  @moduledoc false

  alias Responder.Emisar.ApprovalContract
  alias Responder.State.Records
  alias Responder.StateTools.FixedTools

  @fixed_tool_names ~w(
    get_work_state cite_source record_finding request_input wait_for list_automations get_automation
    propose_automation plan_goal update_goal request_task search_memory propose_memory
    update_conversation_summary record_feedback validate_final
  )

  @spec list(keyword() | map()) :: [map()]
  def list(options \\ %{}) do
    tools = FixedTools.list(options)

    if is_binary(emisar_rpc_url(options)),
      do: tools ++ [emisar_approval_tool()],
      else: tools
  end

  @spec call(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments, options) when name in @fixed_tool_names,
    do: FixedTools.call(name, arguments, options)

  def call("record_emisar_approval", arguments, options) do
    payload_fields =
      ~w(action_id approval_url expires_at operation_id pack_ref request_id run_id runner_ref status)

    with rpc_url when is_binary(rpc_url) <- emisar_rpc_url(options),
         :ok <- exact_fields(arguments, payload_fields),
         {:ok, payload} <-
           ApprovalContract.authorize(
             Map.take(arguments, payload_fields),
             rpc_url,
             DateTime.utc_now()
           ),
         {:ok, state_token} <- state_token(options),
         {:ok, record} <-
           Records.create(
             state_token,
             record_operation_id(payload),
             "emisar_approval",
             payload
           ) do
      {:ok, result(record)}
    else
      nil -> {:error, "not_configured"}
      {:error, :unauthorized} -> {:error, "unauthorized"}
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  def call(name, arguments, options) do
    if name in FixedTools.names() do
      FixedTools.call(name, arguments, options)
    else
      {:error, "unknown_tool"}
    end
  end

  defp result(record) do
    %{
      "continuation" => record.continuation,
      "kind" => record.kind,
      "record_ref" => record.ref
    }
  end

  defp emisar_approval_tool do
    string = fn maximum -> %{"maxLength" => maximum, "minLength" => 1, "type" => "string"} end

    properties = %{
      "action_id" => string.(200),
      "approval_url" => string.(2_048),
      "expires_at" => string.(64),
      "operation_id" => string.(200),
      "pack_ref" => string.(300),
      "request_id" => string.(80),
      "run_id" => string.(200),
      "runner_ref" => string.(300),
      "status" => %{"const" => "pending_approval", "type" => "string"}
    }

    %{
      "description" =>
        "Register the exact pending-approval receipt returned by an Emisar governed action so Responder can wait and resume safely.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => properties,
        "required" => Map.keys(properties) |> Enum.sort(),
        "type" => "object"
      },
      "name" => "record_emisar_approval"
    }
  end

  defp record_operation_id(payload) do
    digest =
      payload
      |> Responder.CanonicalJSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "host:emisar:" <> digest
  end

  defp exact_fields(arguments, fields) when is_map(arguments) do
    if Enum.sort(Map.keys(arguments)) == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp exact_fields(_arguments, _fields), do: {:error, :invalid_arguments}

  defp error_code(:state_record_unauthorized), do: "unauthorized"
  defp error_code(:state_record_confirmation_unsupported), do: "confirmation_unsupported"
  defp error_code(:state_record_shadow_forbidden), do: "unauthorized"
  defp error_code(:state_record_operation_conflict), do: "operation_conflict"
  defp error_code(:state_record_subject_conflict), do: "operation_conflict"
  defp error_code(:invalid_arguments), do: "invalid_arguments"
  defp error_code({:invalid_state_record, _field}), do: "invalid_arguments"
  defp error_code({:invalid_emisar_approval, _field}), do: "invalid_arguments"
  defp error_code(_reason), do: "temporarily_unavailable"

  defp emisar_rpc_url(options) when is_list(options) do
    if Keyword.keyword?(options), do: Keyword.get(options, :emisar_rpc_url), else: nil
  end

  defp emisar_rpc_url(%{} = options), do: Map.get(options, :emisar_rpc_url)
  defp emisar_rpc_url(_options), do: nil

  defp state_token(options) when is_list(options) do
    if Keyword.keyword?(options), do: options |> Map.new() |> state_token(), else: nil
  end

  defp state_token(%{binding: %{state_token: state_token}}) when is_binary(state_token),
    do: {:ok, state_token}

  defp state_token(%{"binding" => %{"state_token" => state_token}})
       when is_binary(state_token),
       do: {:ok, state_token}

  defp state_token(_options), do: {:error, :unauthorized}
end
