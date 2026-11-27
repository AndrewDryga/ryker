defmodule Ryker.CoopFleet.ModelTransfer do
  @moduledoc "Offline Coop account import. Pending receive keys use the controller's encrypted credential store."
  alias Ryker.{AdvisoryLock, Credentials, Repo, Settings}
  alias Ryker.CoopFleet.{ModelAccounts, ModelImportReceipt}

  @maximum 4 * 1_024 * 1_024
  @rsa_options [rsa_padding: :rsa_pkcs1_oaep_padding, rsa_oaep_md: :sha256, rsa_mgf1_md: :sha256]

  def receive_code(reference, actor) do
    with {:ok, provider, account} <- account_parts(reference) do
      name = provider <> ":" <> account

      Repo.transaction(fn ->
        AdvisoryLock.hold!("model-import:" <> name)
        key = receive_key!(name, actor)
        code(provider, account, key)
      end)
    end
  end

  defp receive_key!(name, actor) do
    case Credentials.fetch(:model_import, name) do
      {:ok, stored} ->
        decode_private(stored)

      {:error, :credential_missing} ->
        key = :public_key.generate_key({:rsa, 2048, 65_537})
        der = :public_key.der_encode(:RSAPrivateKey, key)
        write!(Credentials.put(:model_import, name, Base.encode64(der), actor))
        key

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  def receive_bundle(reference, target, bundle, actor)
      when is_binary(bundle) and byte_size(bundle) <= @maximum * 2 do
    with {:ok, provider, account} <- account_parts(reference),
         {:ok, ^provider, local} <- account_parts(target),
         {:ok, key_der} <- Credentials.fetch(:model_import, provider <> ":" <> account),
         key = decode_private(key_der),
         {:ok, %{"provider" => ^provider, "account" => ^account, "id" => id} = payload} <-
           open(key, code(provider, account, key), bundle),
         true <- is_binary(id) and byte_size(id) == 32,
         {:ok, id} <- Base.decode16(id, case: :lower),
         {:ok, uuid} <- Ecto.UUID.load(id) do
      Repo.transaction(fn ->
        store_received!(provider <> ":" <> local, uuid, target, payload, actor)
      end)
    else
      _invalid -> {:error, :invalid_account_bundle}
    end
  end

  def receive_bundle(_, _, _, _), do: {:error, :invalid_account_bundle}

  defp store_received!(name, uuid, target, payload, actor) do
    AdvisoryLock.hold!("model-account:" <> name)

    if Credentials.status(:model_account, name).status != :missing,
      do: Repo.rollback(:account_already_configured)

    claim!(uuid, target)
    write!(save(target, payload, actor))
  end

  defp claim!(id, target) do
    case Repo.insert_all(ModelImportReceipt, [%{id: id, account: target}], on_conflict: :nothing) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:already_imported)
    end
  end

  defp account_parts(reference) do
    with true <- is_binary(reference) and Settings.Work.account?(reference),
         [provider, account] when provider in ["codex", "claude"] <-
           String.split(reference, "@", parts: 2),
         {:ok, settings} <- Settings.fetch(),
         true <- reference in settings.work.model_accounts do
      {:ok, provider, account}
    else
      _invalid -> {:error, :invalid_model_account}
    end
  end

  defp code(provider, account, key) do
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    encoded = :public_key.der_encode(:RSAPublicKey, public) |> Base.url_encode64(padding: false)

    body =
      Ryker.CanonicalJSON.encode!(%{
        "destination" => "ryker",
        "provider" => provider,
        "account" => account,
        "key" => encoded
      })

    "coop-import-1." <> Base.url_encode64(body, padding: false)
  end

  defp decode(data), do: Base.url_decode64(data, padding: false)
  defp decode_private(data), do: :public_key.der_decode(:RSAPrivateKey, Base.decode64!(data))

  defp open(key, invitation, bundle) do
    compact = String.replace(bundle, ~r/[\r\n\t ]+/, "")

    expected = %{
      "alg" => "RSA-OAEP-256",
      "enc" => "A256GCM",
      "kid" => Base.url_encode64(Ryker.Crypto.sha256(invitation), padding: false)
    }

    with [header, wrapped, nonce, data, tag] <- String.split(compact, ".", parts: 6),
         {:ok, json} <- decode(header),
         {:ok, ^expected} <- Jason.decode(json),
         {:ok, wrapped} when byte_size(wrapped) == 256 <- decode(wrapped),
         {:ok, nonce} when byte_size(nonce) == 12 <- decode(nonce),
         {:ok, ciphertext} <- decode(data),
         {:ok, tag} when byte_size(tag) == 16 <- decode(tag),
         <<cek::binary-size(32)>> <- :public_key.decrypt_private(wrapped, key, @rsa_options),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, cek, nonce, ciphertext, header, tag, false) do
      Jason.decode(plain)
    else
      _invalid -> {:error, :invalid_account_bundle}
    end
  rescue
    _invalid -> {:error, :invalid_account_bundle}
  end

  defp save(reference, %{"api_key" => key} = payload, actor) when map_size(payload) == 4,
    do: ModelAccounts.put_key(reference, key, actor)

  defp save(
         reference,
         %{"provider" => "codex", "files" => %{"auth.json" => auth} = files} = payload,
         actor
       )
       when map_size(payload) == 4 and map_size(files) == 1 and is_binary(auth) do
    with {:ok, json} <- Base.decode64(auth),
         do: ModelAccounts.import_account(reference, %{"auth.json" => json}, actor)
  end

  defp save(_, _, _), do: {:error, :unsupported_account}
  defp write!({:ok, metadata}), do: metadata
  defp write!(:error), do: Repo.rollback(:invalid_account_bundle)
  defp write!(:ok), do: :ok
  defp write!({:error, reason}), do: Repo.rollback(reason)
end
