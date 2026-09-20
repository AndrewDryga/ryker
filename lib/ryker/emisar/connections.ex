defmodule Ryker.Emisar.Connections do
  @moduledoc "Trusted resolution of scoped Emisar authority and isolated clients."

  alias Ryker.{Credentials, Settings}

  @spec resolve(Settings.snapshot(), String.t() | nil, map() | nil, atom()) ::
          {:ok, map()} | {:error, :not_configured | :disabled}
  def resolve(snapshot, repository_ref, repository_context, purpose \\ :standard) do
    {scope_kind, scope_ref} = scope(repository_ref, repository_context, purpose)

    with binding when not is_nil(binding) <-
           Enum.find(snapshot.emisar_bindings, fn binding ->
             binding.scope_kind == scope_kind and binding.scope_ref == scope_ref and
               binding.purpose == purpose
           end),
         connection when not is_nil(connection) <-
           Enum.find(snapshot.emisar_connections, &(&1.ref == binding.connection_ref)),
         true <- connection.enabled_for_new_work do
      {:ok,
       %{
         connection_ref: connection.ref,
         account_ref: connection.account_ref,
         rpc_url: connection.rpc_url
       }}
    else
      false -> {:error, :disabled}
      nil -> {:error, :not_configured}
    end
  end

  @spec credential_provider(String.t()) :: (-> {:ok, String.t()} | {:error, term()})
  def credential_provider(connection_ref), do: Credentials.provider(:emisar, connection_ref)

  defp scope(_repository_ref, %{"context_ref" => ref}, _purpose) when is_binary(ref),
    do: {:context, ref}

  defp scope(_repository_ref, %{context_ref: ref}, _purpose) when is_binary(ref),
    do: {:context, ref}

  defp scope(repository_ref, _context, _purpose) when is_binary(repository_ref),
    do: {:repository, repository_ref}

  defp scope(nil, _context, purpose), do: {:installation_purpose, Atom.to_string(purpose)}
end
