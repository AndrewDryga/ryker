defmodule Ryker.Settings.EmisarConnection do
  @moduledoc "A verified Emisar account connection; its bearer remains in credential custody."

  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(ref display_name rpc_url account_ref account_label enabled_for_new_work monitoring_enabled verified_at)a

  schema "emisar_connection_settings" do
    field(:display_name, :string)
    field(:rpc_url, :string)
    field(:account_ref, :string)
    field(:account_label, :string)
    field(:enabled_for_new_work, :boolean, default: true)
    field(:monitoring_enabled, :boolean, default: true)
    field(:verified_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}

  def find(snapshot, :ref, ref),
    do: Enum.find(snapshot.emisar_connections, &(&1.ref == ref))

  def changeset(current, attributes, _snapshot) do
    current
    |> cast(attributes, @fields)
    |> validate_required([:ref, :display_name, :rpc_url, :account_ref, :verified_at])
    |> Validation.validate_reference(:ref)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:account_ref, min: 1, max: 256)
    |> validate_length(:account_label, min: 1, max: 256)
    |> validate_rpc_url()
    |> unique_constraint(:account_ref,
      name: :emisar_connection_endpoint_account_index,
      message: "is already connected at this endpoint"
    )
  end

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

  defp validate_rpc_url(changeset) do
    validate_change(changeset, :rpc_url, fn :rpc_url, value ->
      case endpoint(value) do
        {:ok, _endpoint} ->
          []

        :error ->
          [
            rpc_url:
              {"must be an HTTPS endpoint without credentials, query or fragment",
               [validation: :format]}
          ]
      end
    end)
  end
end
