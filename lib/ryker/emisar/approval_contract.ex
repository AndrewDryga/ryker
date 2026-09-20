defmodule Ryker.Emisar.ApprovalContract do
  @moduledoc """
  Exact, host-checkable identity for one Emisar approval hold.

  The model may relay this document after an Emisar tool call, but it cannot
  choose the trusted origin. The state-tool boundary supplies the configured
  Emisar RPC URL and rejects foreign, expired, incomplete, or mutable links
  before a durable record can be created.
  """

  alias Ryker.CanonicalJSON

  @fields ~w(action_id approval_url expires_at operation_id pack_ref request_id run_id runner_ref status)
  @host_fields ~w(account_ref connection_ref rpc_url)
  @maximum_payload_bytes 8 * 1_024

  @spec prepare(term(), String.t()) ::
          {:ok, %{payload: map(), continuation: map(), subject_ref: nil}} | {:error, term()}
  def prepare(%{} = payload, record_ref) do
    with :ok <- exact_fields(payload),
         :ok <- text(payload["request_id"], 80, :request_id),
         :ok <- text(payload["run_id"], 200, :run_id),
         :ok <- text(payload["operation_id"], 200, :operation_id),
         :ok <- text(payload["action_id"], 200, :action_id),
         :ok <- text(payload["pack_ref"], 300, :pack_ref),
         :ok <- text(payload["runner_ref"], 300, :runner_ref),
         :ok <- status(payload["status"]),
         {:ok, expires_at} <- utc_datetime(payload["expires_at"]),
         {:ok, approval_url} <- approval_url(payload["approval_url"], payload["request_id"]),
         :ok <- host_authority(payload),
         prepared <- %{
           payload
           | "approval_url" => approval_url,
             "expires_at" => DateTime.to_iso8601(expires_at)
         },
         :ok <- canonical(prepared) do
      {:ok,
       %{
         continuation: %{
           "deadline_at" => DateTime.to_iso8601(expires_at),
           "kind" => "wait",
           "wait_kind" => "event",
           "wait_ref" => record_ref
         },
         payload: prepared,
         subject_ref: nil
       }}
    end
  end

  def prepare(_payload, _record_ref),
    do: {:error, {:invalid_emisar_approval, :payload}}

  @spec authorize(term(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def authorize(payload, rpc_url, %DateTime{} = now) do
    with {:ok, prepared} <- prepare(payload, "record:emisar_approval:validation"),
         :ok <- same_origin(prepared.payload["approval_url"], rpc_url),
         {:ok, expires_at} <- utc_datetime(prepared.payload["expires_at"]),
         :ok <- future(expires_at, now) do
      {:ok, prepared.payload}
    end
  end

  def authorize(_payload, _rpc_url, _now),
    do: {:error, {:invalid_emisar_approval, :authority}}

  defp exact_fields(payload) do
    keys = Map.keys(payload) |> Enum.sort()

    if keys in [@fields, Enum.sort(@fields ++ @host_fields)],
      do: :ok,
      else: {:error, {:invalid_emisar_approval, :fields}}
  end

  defp host_authority(%{
         "connection_ref" => connection_ref,
         "account_ref" => account_ref,
         "rpc_url" => rpc_url,
         "approval_url" => approval_url
       }) do
    with :ok <- text(connection_ref, 64, :connection_ref),
         :ok <- text(account_ref, 256, :account_ref) do
      same_origin(approval_url, rpc_url)
    end
  end

  defp host_authority(_model_payload), do: :ok

  defp status("pending_approval"), do: :ok
  defp status(_status), do: {:error, {:invalid_emisar_approval, :status}}

  defp text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_emisar_approval, field}}
  end

  defp utc_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, normalize(datetime)}
      _invalid -> {:error, {:invalid_emisar_approval, :expires_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_emisar_approval, :expires_at}}

  defp approval_url(value, request_id) do
    with :ok <- text(value, 2_048, :approval_url),
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri <-
           URI.parse(String.trim(value)),
         true <- is_binary(host) and host != "",
         true <- approval_path?(uri.path, request_id) do
      {:ok, URI.to_string(uri)}
    else
      _invalid -> {:error, {:invalid_emisar_approval, :approval_url}}
    end
  end

  defp approval_path?(path, request_id) when is_binary(path) do
    path = String.trim_trailing(path, "/")

    String.starts_with?(path, "/app/") and String.contains?(path, "/approvals/") and
      String.ends_with?(path, "/" <> URI.encode(request_id, &URI.char_unreserved?/1))
  end

  defp approval_path?(_path, _request_id), do: false

  defp same_origin(approval_url, rpc_url) do
    with %URI{scheme: "https", host: approval_host, port: approval_port} <-
           URI.parse(approval_url),
         %URI{
           scheme: "https",
           host: rpc_host,
           port: rpc_port,
           userinfo: nil,
           query: nil,
           fragment: nil
         } <- URI.parse(rpc_url),
         true <- is_binary(rpc_host) and rpc_host != "",
         true <-
           String.downcase(approval_host) == String.downcase(rpc_host) and
             effective_port("https", approval_port) == effective_port("https", rpc_port) do
      :ok
    else
      _invalid -> {:error, {:invalid_emisar_approval, :approval_origin}}
    end
  end

  defp effective_port("https", nil), do: 443
  defp effective_port(_scheme, port), do: port

  defp future(expires_at, now) do
    if DateTime.compare(expires_at, normalize(now)) == :gt,
      do: :ok,
      else: {:error, {:invalid_emisar_approval, :expires_at}}
  end

  defp canonical(payload) do
    case CanonicalJSON.validate(payload, max_bytes: @maximum_payload_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_emisar_approval, :payload}}
    end
  end

  defp normalize(%DateTime{microsecond: {microsecond, _precision}} = datetime),
    do: %{datetime | microsecond: {microsecond, 6}}
end
