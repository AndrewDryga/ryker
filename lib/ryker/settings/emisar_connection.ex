defmodule Ryker.Settings.EmisarConnection do
  @moduledoc "A verified Emisar account connection; its bearer remains in credential custody."
  use Ryker, :schema

  @primary_key {:ref, :string, autogenerate: false}

  schema "emisar_connection_settings" do
    field(:display_name, :string)
    field(:rpc_url, :string)
    field(:account_ref, :string)
    field(:account_label, :string)
    field(:enabled_for_new_work, :boolean, default: true)
    field(:monitoring_enabled, :boolean, default: true)
    field(:verified_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  The parts of an Emisar RPC address: the exact HTTPS endpoint, never an
  origin to guess a path from, with no credentials, query or fragment.
  """
  @spec endpoint(term()) ::
          {:ok, %{origin: String.t(), path: String.t(), url: String.t()}} | :error
  def endpoint(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and is_binary(path) and path != "" ->
        origin = uri |> Map.put(:path, nil) |> URI.to_string() |> String.trim_trailing("/")
        {:ok, %{origin: origin, path: path, url: URI.to_string(uri)}}

      _invalid ->
        :error
    end
  end

  def endpoint(_url), do: :error
end
