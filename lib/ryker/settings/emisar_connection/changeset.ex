defmodule Ryker.Settings.EmisarConnection.Changeset do
  @moduledoc """
  Connecting an Emisar account and changing a saved connection
  (`Ryker.Settings.EmisarConnection`).
  """
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.{EmisarConnection, Validation}

  @fields ~w(ref display_name rpc_url account_ref account_label enabled_for_new_work monitoring_enabled verified_at)a

  @impl true
  def fields, do: @fields

  @impl true
  def insert(attributes, _snapshot),
    do: %EmisarConnection{} |> cast(attributes, @fields) |> changeset()

  @impl true
  def update(%EmisarConnection{} = connection, attributes, _snapshot),
    do: connection |> cast(attributes, @fields) |> changeset()

  defp changeset(changeset) do
    changeset
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

  defp validate_rpc_url(changeset) do
    validate_change(changeset, :rpc_url, fn :rpc_url, value ->
      case EmisarConnection.endpoint(value) do
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
