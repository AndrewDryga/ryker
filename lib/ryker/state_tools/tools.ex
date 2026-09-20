defmodule Ryker.StateTools.Tools do
  @moduledoc false

  alias Ryker.CanonicalJSON
  alias Ryker.Emisar.ApprovalContract
  alias Ryker.State.Records
  alias Ryker.StateTools.{ErrorCode, FixedTools}

  @fixed_tool_names FixedTools.names()

  @spec list(keyword() | map()) :: [map()]
  def list(options \\ %{}) do
    tools = FixedTools.list(options)

    if match?({:ok, _authority}, emisar_authority(options)),
      do: tools ++ [emisar_approval_tool()],
      else: tools
  end

  @spec call(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments, options) when name in @fixed_tool_names,
    do: FixedTools.call(name, arguments, options)

  def call("record_emisar_approval", arguments, options) do
    payload_fields =
      ~w(action_id approval_url expires_at operation_id pack_ref request_id run_id runner_ref status)

    with {:ok, authority} <- emisar_authority(options),
         :ok <- exact_fields(arguments, payload_fields),
         {:ok, payload} <-
           ApprovalContract.authorize(
             Map.take(arguments, payload_fields),
             authority.rpc_url,
             DateTime.utc_now()
           ),
         payload <-
           Map.merge(payload, %{
             "connection_ref" => authority.connection_ref,
             "account_ref" => authority.account_ref,
             "rpc_url" => authority.rpc_url
           }),
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
      {:error, :not_configured} -> {:error, "not_configured"}
      {:error, reason} -> {:error, ErrorCode.code(reason)}
    end
  end

  def call(_name, _arguments, _options), do: {:error, "unknown_tool"}

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
        "Register the exact pending-approval receipt returned by an Emisar governed action so Ryker can wait and resume safely.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => properties,
        "required" => Map.keys(properties) |> Enum.sort(),
        "type" => "object"
      },
      "name" => "record_emisar_approval"
    }
  end

  defp record_operation_id(payload), do: "host:emisar:" <> CanonicalJSON.digest(payload)

  defp exact_fields(arguments, fields) when is_map(arguments) do
    if Enum.sort(Map.keys(arguments)) == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_arguments}
  end

  defp exact_fields(_arguments, _fields), do: {:error, :invalid_arguments}

  defp emisar_authority(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: options |> Map.new() |> emisar_authority(),
      else: {:error, :not_configured}
  end

  defp emisar_authority(%{
         binding: %{
           session: %{
             emisar_connection_ref: ref,
             emisar_account_ref: account,
             emisar_rpc_url: url
           }
         }
       })
       when is_binary(ref) and is_binary(account) and is_binary(url),
       do: {:ok, %{connection_ref: ref, account_ref: account, rpc_url: url}}

  defp emisar_authority(_options), do: {:error, :not_configured}

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
