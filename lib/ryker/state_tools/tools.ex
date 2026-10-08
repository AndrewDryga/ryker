defmodule Ryker.StateTools.Tools do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Emisar
  alias Ryker.Maps
  alias Ryker.Records
  alias Ryker.StateTools.{ErrorCode, FixedTools}
  alias Ryker.Work

  @spec list(keyword() | map()) :: [map()]
  def list(options \\ %{}) do
    tools = FixedTools.list(options)

    if approval_receipts?(options),
      do: tools ++ [emisar_approval_tool()],
      else: tools
  end

  # A turn records an approval receipt only as live work in an environment
  # with Emisar: an evaluation run, which only observes, was offered one it
  # could never record (2026-10-04 review).
  defp approval_receipts?(options) do
    Work.Contract.fixed_tool_allowed?(
      FixedTools.execution_mode(options),
      "record_emisar_approval"
    ) and
      match?({:ok, _authority}, emisar_authority(options))
  end

  @spec call(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def call("record_emisar_approval", arguments, options) do
    payload_fields =
      ~w(action_id approval_url expires_at operation_id pack_ref request_id run_id runner_ref status)

    with true <- approval_receipts?(options) || {:error, :not_configured},
         {:ok, authority} <- emisar_authority(options),
         true <- Maps.exact_keys?(arguments, payload_fields) || {:error, :invalid_arguments},
         {:ok, payload} <-
           Emisar.ApprovalContract.authorize(
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

  # The fixed tools are asked for their names when a call comes: a guard
  # built from `FixedTools.names/0` at compile time put this catalog in Ryker's
  # one compile cycle (2026-10-08).
  def call(name, arguments, options) do
    if name in FixedTools.names(),
      do: FixedTools.call(name, arguments, options),
      else: {:error, "unknown_tool"}
  end

  @doc "The Emisar account of the session's environment, when it has one."
  @spec emisar_pin(keyword() | map()) :: {:ok, map()} | {:error, :not_configured}
  def emisar_pin(options), do: emisar_authority(options)

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
    if Keyword.keyword?(options),
      do: options |> Map.new() |> state_token(),
      else: {:error, :unauthorized}
  end

  defp state_token(%{binding: %{state_token: state_token}}) when is_binary(state_token),
    do: {:ok, state_token}

  defp state_token(_options), do: {:error, :unauthorized}
end
