defmodule Ryker.Credentials do
  @moduledoc """
  Encrypted custody for integration credentials.

  Callers address one reviewed credential kind and name. Reads return only that
  credential's plaintext; discovery and inspection return status metadata only.
  """

  import Ecto.Query

  alias Ryker.Credentials.{Credential, Event}
  alias Ryker.Repo

  @key_version 1
  @pubsub Ryker.ControlPlane.PubSub
  @topic "credentials"
  @nonce_bytes 12
  @tag_bytes 16
  @maximum_bytes 1_048_576
  @kinds [:slack_app, :slack_bot, :github_private_key, :github_webhook, :emisar, :webhook]
  @name ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/

  @type kind ::
          :slack_app | :slack_bot | :github_private_key | :github_webhook | :emisar | :webhook

  @doc "Notifies a runtime owner after committed credential changes."
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @spec put(kind(), String.t(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put(kind, name, plaintext, actor_ref) do
    result =
      with :ok <- validate_identity(kind, name),
           :ok <- validate_plaintext(plaintext),
           :ok <- validate_actor(actor_ref),
           {:ok, sealed} <- seal(root_key(), kind, name, plaintext) do
        Repo.transaction(fn -> put_locked(kind, name, actor_ref, sealed) end)
        |> unwrap_transaction()
      end

    notify(result, kind, name)
  end

  @spec fetch(kind(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(kind, name) do
    with :ok <- validate_identity(kind, name),
         %Credential{} = credential <- Repo.get_by(Credential, kind: kind, name: name),
         {:ok, plaintext} <- open(root_key(), credential) do
      {:ok, plaintext}
    else
      nil -> {:error, :credential_missing}
      {:error, _reason} = error -> error
    end
  end

  @spec provider(kind(), String.t()) :: (-> {:ok, binary()} | {:error, term()})
  def provider(kind, name), do: fn -> fetch(kind, name) end

  @spec status(kind(), String.t()) :: map()
  def status(kind, name) do
    case validate_identity(kind, name) do
      :ok ->
        case Repo.get_by(Credential, kind: kind, name: name) do
          nil -> %{kind: kind, name: name, status: :missing}
          %Credential{} = credential -> metadata(credential)
        end

      {:error, _reason} ->
        %{kind: kind, name: name, status: :invalid}
    end
  end

  @spec statuses() :: [map()]
  def statuses do
    Credential
    |> order_by([credential], asc: credential.kind, asc: credential.name)
    |> Repo.all()
    |> Enum.map(&metadata/1)
  end

  @spec verify(kind(), String.t(), :verified | :invalid, String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify(kind, name, verification_status, actor_ref)
      when verification_status in [:verified, :invalid] do
    result =
      with :ok <- validate_identity(kind, name),
           :ok <- validate_actor(actor_ref) do
        Repo.transaction(fn -> verify_locked(kind, name, verification_status, actor_ref) end)
        |> unwrap_transaction()
      end

    notify(result, kind, name)
  end

  def verify(_kind, _name, _verification_status, _actor_ref),
    do: {:error, :credential_verification_status_invalid}

  @spec delete(kind(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(kind, name, actor_ref) do
    result =
      with :ok <- validate_identity(kind, name),
           :ok <- validate_actor(actor_ref) do
        Repo.transaction(fn -> delete_locked(kind, name, actor_ref) end)
        |> unwrap_transaction()
      end

    notify(result, kind, name)
  end

  defp put_locked(kind, name, actor_ref, sealed) do
    now = Repo.now!()

    case Repo.get_by(Credential, kind: kind, name: name) do
      nil ->
        credential =
          %Credential{
            id: Ecto.UUID.generate(),
            kind: kind,
            name: name,
            inserted_at: now
          }
          |> Ecto.Changeset.change(
            Map.merge(sealed, %{
              verification_status: :unverified,
              verified_at: nil,
              updated_at: now
            })
          )
          |> Repo.insert!()

        event!(credential, :created, actor_ref, now)
        metadata(credential)

      %Credential{} = credential ->
        credential =
          credential
          |> Ecto.Changeset.change(
            Map.merge(sealed, %{
              verification_status: :unverified,
              verified_at: nil,
              updated_at: now
            })
          )
          |> Repo.update!()

        event!(credential, :replaced, actor_ref, now)
        metadata(credential)
    end
  end

  defp verify_locked(kind, name, verification_status, actor_ref) do
    case Repo.get_by(Credential, kind: kind, name: name) do
      nil ->
        Repo.rollback(:credential_missing)

      %Credential{} = credential ->
        now = Repo.now!()

        credential =
          credential
          |> Ecto.Changeset.change(
            verification_status: verification_status,
            verified_at: if(verification_status == :verified, do: now),
            updated_at: now
          )
          |> Repo.update!()

        action = if verification_status == :verified, do: :verified, else: :invalidated
        event!(credential, action, actor_ref, now)
        metadata(credential)
    end
  end

  defp delete_locked(kind, name, actor_ref) do
    case Repo.get_by(Credential, kind: kind, name: name) do
      nil ->
        :ok

      %Credential{} = credential ->
        now = Repo.now!()
        event!(credential, :deleted, actor_ref, now)
        Repo.delete!(credential)
        :ok
    end
  end

  defp event!(credential, action, actor_ref, now) do
    %Event{
      id: Ecto.UUID.generate(),
      credential_id: credential.id,
      kind: credential.kind,
      name: credential.name,
      action: action,
      actor_ref: actor_ref,
      fingerprint: credential.fingerprint,
      inserted_at: now
    }
    |> Repo.insert!()
  end

  defp metadata(credential) do
    %{
      kind: credential.kind,
      name: credential.name,
      status: :configured,
      verification_status: credential.verification_status,
      fingerprint: credential.fingerprint,
      verified_at: credential.verified_at,
      updated_at: credential.updated_at
    }
  end

  defp seal(key, kind, name, plaintext) when byte_size(key) == 32 do
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        associated_data(kind, name, @key_version),
        @tag_bytes,
        true
      )

    {:ok,
     %{
       key_version: @key_version,
       ciphertext: ciphertext,
       nonce: nonce,
       tag: tag,
       fingerprint: digest(plaintext)
     }}
  rescue
    _error -> {:error, :credential_encryption_failed}
  end

  defp open(key, %Credential{} = credential) when byte_size(key) == 32 do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           credential.nonce,
           credential.ciphertext,
           associated_data(credential.kind, credential.name, credential.key_version),
           credential.tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _error -> {:error, :credential_decryption_failed}
    end
  rescue
    _error -> {:error, :credential_decryption_failed}
  end

  defp associated_data(kind, name, version),
    do:
      Enum.join(
        ["ryker-integration-credential", Integer.to_string(version), to_string(kind), name],
        <<0>>
      )

  defp validate_identity(kind, name) when kind in @kinds and is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :credential_name_invalid}
  end

  defp validate_identity(_kind, _name), do: {:error, :credential_identity_invalid}

  defp validate_plaintext(plaintext)
       when is_binary(plaintext) and byte_size(plaintext) in 1..@maximum_bytes,
       do: :ok

  defp validate_plaintext(_plaintext), do: {:error, :credential_value_invalid}

  defp validate_actor(actor_ref) when is_binary(actor_ref) and byte_size(actor_ref) in 1..256,
    do: :ok

  defp validate_actor(_actor_ref), do: {:error, :credential_actor_invalid}

  defp root_key do
    case Application.fetch_env(:ryker, :credential_key) do
      {:ok, key} when is_binary(key) and byte_size(key) == 32 -> key
      _missing_or_invalid -> raise "RYKER_CREDENTIAL_KEY is missing or invalid"
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp notify({:ok, _value} = result, kind, name) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:credentials_changed, kind, name})
    result
  end

  defp notify(result, _kind, _name), do: result

  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
