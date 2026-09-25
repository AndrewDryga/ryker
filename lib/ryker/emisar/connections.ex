defmodule Ryker.Emisar.Connections do
  @moduledoc """
  Trusted resolution of the Emisar account work may use, and isolated clients.

  The account belongs to the environment work runs in. A session pins it once,
  when its first generation is created, and later generations copy that pin;
  work outside any environment, in an environment without an account, or in
  one whose account is closed to new work has no Emisar authority.
  """

  alias Ryker.{Credentials, Settings}
  alias Ryker.Settings.Environment

  @type pin :: %{connection_ref: String.t(), account_ref: String.t(), rpc_url: String.t()}

  @spec resolve(Settings.snapshot(), String.t() | nil) ::
          {:ok, pin()} | {:error, :not_configured | :disabled}
  def resolve(_snapshot, nil), do: {:error, :not_configured}

  def resolve(snapshot, environment_ref) when is_binary(environment_ref) do
    with %Environment{emisar_connection_ref: ref} when is_binary(ref) <-
           Environment.find(snapshot, :ref, environment_ref),
         connection when not is_nil(connection) <-
           Enum.find(snapshot.emisar_connections, &(&1.ref == ref)),
         true <- connection.enabled_for_new_work do
      {:ok,
       %{
         connection_ref: connection.ref,
         account_ref: connection.account_ref,
         rpc_url: connection.rpc_url
       }}
    else
      false -> {:error, :disabled}
      _unconfigured -> {:error, :not_configured}
    end
  end

  @spec credential_provider(String.t()) :: (-> {:ok, String.t()} | {:error, term()})
  def credential_provider(connection_ref), do: Credentials.provider(:emisar, connection_ref)
end
