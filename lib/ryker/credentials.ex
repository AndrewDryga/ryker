defmodule Ryker.Credentials do
  @moduledoc """
  Encrypted custody for integration credentials.

  Callers address one reviewed credential kind and name. Reads return only that
  credential's plaintext; discovery and inspection return status metadata only.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Config
  alias Ryker.Credential
  alias Ryker.Crypto
  alias Ryker.Repo
  require Logger

  @key_version 1
  @minimum_bytes 8
  @maximum_bytes 1_048_576
  @kinds [:slack_app, :slack_bot, :github_private_key, :github_webhook, :emisar, :webhook]
  @name ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/

  @type kind ::
          :slack_app | :slack_bot | :github_private_key | :github_webhook | :emisar | :webhook

  @doc """
  Seals and stores the credential `kind`/`name` as `actor_ref`, replacing any
  previous value and its verification: `{:ok, metadata}` (status only, never
  the value), or `{:error, reason}` for an identity, value (8 bytes to
  1 MiB) or actor it refuses.
  """
  @spec put(kind(), String.t(), binary(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def put(kind, name, plaintext, actor_ref) do
    with :ok <- validate_identity(kind, name),
         :ok <- validate_plaintext(plaintext),
         :ok <- validate_actor(actor_ref),
         {:ok, sealed} <- seal(root_key(), kind, name, plaintext) do
      Repo.transaction(fn -> put_locked(kind, name, actor_ref, sealed) end)
    end
  end

  @doc """
  The plaintext of credential `kind`/`name`: `{:ok, plaintext}`, or
  `{:error, :credential_missing | :credential_decryption_failed}` and the
  reasons an identity is refused.
  """
  @spec fetch(kind(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(kind, name) do
    with :ok <- validate_identity(kind, name),
         %Credential{} = credential <- Repo.one(Credential.Query.by_identity(kind, name)),
         {:ok, plaintext} <- open(root_key(), credential) do
      {:ok, plaintext}
    else
      nil -> {:error, :credential_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  A function that reads credential `kind`/`name` when called (`fetch/2`), so
  a client asks for its secret at the moment it uses it.
  """
  @spec provider(kind(), String.t()) :: (-> {:ok, binary()} | {:error, term()})
  def provider(kind, name), do: fn -> fetch(kind, name) end

  @doc """
  The metadata of credential `kind`/`name`, never its value: whether it is
  configured and verified, its fingerprint and times; `status: :missing` when
  nothing is stored and `:invalid` for an identity no credential can have.
  """
  @spec status(kind(), String.t()) :: map()
  def status(kind, name) do
    case validate_identity(kind, name) do
      :ok ->
        case Repo.one(Credential.Query.by_identity(kind, name)) do
          nil -> %{kind: kind, name: name, status: :missing}
          %Credential{} = credential -> metadata(credential)
        end

      {:error, _reason} ->
        %{kind: kind, name: name, status: :invalid}
    end
  end

  @doc "The metadata of every stored credential, by kind and name (`status/2`)."
  @spec statuses() :: [map()]
  def statuses do
    Credential.Query.all()
    |> Credential.Query.ordered_by_identity()
    |> Repo.all()
    |> Enum.map(&metadata/1)
  end

  @doc """
  The value of every saved credential, for finding and redacting in what Ryker
  keeps or shows: worker checkpoints, examples, inspection views. Read when it
  is needed: carried in the runtime configuration, saving any credential
  changed every lane's configuration and restarted them all (2026-10-04
  review).
  """
  @spec redaction_values() :: [binary()]
  def redaction_values do
    statuses()
    |> Enum.flat_map(fn credential ->
      case fetch(credential.kind, credential.name) do
        {:ok, value} ->
          [value]

        # One that no longer decrypts, after a key change, dropped out without a
        # word, so its value could reach worker output unmasked (2026-10-04 review).
        {:error, reason} ->
          Logger.warning(
            "credential #{credential.kind}/#{credential.name} could not be read (#{reason}), " <>
              "so its value is not redacted"
          )

          []
      end
    end)
    |> Enum.uniq()
  end

  @remembered {__MODULE__, :redaction_values}

  @doc """
  Reads the saved credential values and keeps them for
  `remembered_redaction_values/0`. The runtime does this each time it applies
  settings, which saving or removing a credential triggers.
  """
  @spec remember_redaction_values() :: [binary()]
  def remember_redaction_values do
    values = redaction_values()

    unless :persistent_term.get(@remembered, nil) == values,
      do: :persistent_term.put(@remembered, values)

    values
  end

  @doc """
  The saved credential values the runtime last read, without reading the
  database: what a page or a log redacts with on every read.
  """
  @spec remembered_redaction_values() :: [binary()]
  def remembered_redaction_values, do: :persistent_term.get(@remembered, [])

  @doc """
  Records that credential `kind`/`name` was checked with its provider and
  found `:verified` or `:invalid`: `{:ok, metadata}`, or
  `{:error, :credential_missing}` for one never stored.
  """
  @spec verify(kind(), String.t(), :verified | :invalid, String.t()) ::
          {:ok, map()} | {:error, term()}
  def verify(kind, name, verification_status, actor_ref)
      when verification_status in [:verified, :invalid] do
    with :ok <- validate_identity(kind, name),
         :ok <- validate_actor(actor_ref) do
      Repo.transaction(fn -> verify_locked(kind, name, verification_status, actor_ref) end)
    end
  end

  def verify(_kind, _name, _verification_status, _actor_ref),
    do: {:error, :credential_verification_status_invalid}

  @doc "Removes a credential. Removing one that is not saved changes and announces nothing."
  @spec delete(kind(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(kind, name, actor_ref) do
    with :ok <- validate_identity(kind, name),
         :ok <- validate_actor(actor_ref),
         {:ok, :ok} <- Repo.transaction(fn -> delete_locked(kind, name, actor_ref) end),
         do: :ok
  end

  defp put_locked(kind, name, actor_ref, sealed) do
    lock!(kind, name)
    now = Repo.now!()
    # A new value has not been checked, whatever the one before it had.
    unverified =
      Map.merge(sealed, %{verification_status: :unverified, verified_at: nil, updated_at: now})

    case Repo.one(Credential.Query.by_identity(kind, name)) do
      nil ->
        credential =
          %Credential{
            id: Repo.generate_id(),
            kind: kind,
            name: name,
            inserted_at: now
          }
          |> Ecto.Changeset.change(unverified)
          |> Repo.insert!()

        event!(credential, :created, actor_ref, now)
        broadcast_credentials_changed(kind, name)
        metadata(credential)

      %Credential{} = credential ->
        credential =
          credential
          |> Ecto.Changeset.change(unverified)
          |> Repo.update!()

        event!(credential, :replaced, actor_ref, now)
        broadcast_credentials_changed(kind, name)
        metadata(credential)
    end
  end

  defp verify_locked(kind, name, verification_status, actor_ref) do
    lock!(kind, name)

    case Repo.one(Credential.Query.by_identity(kind, name)) do
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
        broadcast_credentials_changed(kind, name)
        metadata(credential)
    end
  end

  defp delete_locked(kind, name, actor_ref) do
    lock!(kind, name)

    case Repo.one(Credential.Query.by_identity(kind, name)) do
      nil ->
        :ok

      %Credential{} = credential ->
        now = Repo.now!()
        event!(credential, :deleted, actor_ref, now)
        Repo.delete!(credential)
        broadcast_credentials_changed(kind, name)
        :ok
    end
  end

  # One credential's saves, checks and removals take turns, so two first saves
  # of the same credential cannot both insert it.
  defp lock!(kind, name), do: AdvisoryLock.hold!("ryker-credential:#{kind}:#{name}")

  defp event!(credential, action, actor_ref, now) do
    %Credential.Event{
      id: Repo.generate_id(),
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
    data = associated_data(kind, name, @key_version)
    sealed = Crypto.seal(key, plaintext, data)

    {:ok,
     Map.merge(sealed, %{
       key_version: @key_version,
       fingerprint: fingerprint(key, data, plaintext)
     })}
  rescue
    _error -> {:error, :credential_encryption_failed}
  end

  # Whether a credential's value changed, for its history, and nothing more: keyed by
  # a subkey of the root and bound to the credential's identity. A plain SHA-256 of
  # the secret, beside the ciphertext, let anyone with a dump or a backup check a
  # guess offline and showed two credentials holding one value (2026-10-04 review).
  defp fingerprint(key, associated_data, plaintext) do
    key
    |> Crypto.hmac_sha256("ryker-integration-credential-fingerprint")
    |> Crypto.hmac_sha256([associated_data, <<0>>, plaintext])
    |> Base.encode16(case: :lower)
  end

  defp open(key, %Credential{} = credential) when byte_size(key) == 32 do
    sealed = Map.take(credential, [:nonce, :ciphertext, :tag])
    data = associated_data(credential.kind, credential.name, credential.key_version)

    case Crypto.open(key, sealed, data) do
      {:ok, plaintext} -> {:ok, plaintext}
      :error -> {:error, :credential_decryption_failed}
    end
  rescue
    _error -> {:error, :credential_decryption_failed}
  end

  defp associated_data(kind, name, version) do
    Enum.join(
      ["ryker-integration-credential", Integer.to_string(version), to_string(kind), name],
      <<0>>
    )
  end

  defp validate_identity(kind, name) when kind in @kinds and is_binary(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, :credential_name_invalid}
  end

  defp validate_identity(_kind, _name), do: {:error, :credential_identity_invalid}

  # Every stored secret is also redaction material for worker output, and a
  # value under eight bytes cannot be told apart from ordinary text: the
  # worker server refuses one, and a single short secret failed every later
  # settings apply.
  defp validate_plaintext(plaintext)
       when is_binary(plaintext) and byte_size(plaintext) in @minimum_bytes..@maximum_bytes,
       do: :ok

  defp validate_plaintext(plaintext)
       when is_binary(plaintext) and plaintext != "" and byte_size(plaintext) < @minimum_bytes,
       do: {:error, :credential_value_too_short}

  defp validate_plaintext(_plaintext), do: {:error, :credential_value_invalid}

  defp validate_actor(actor_ref) when is_binary(actor_ref) and byte_size(actor_ref) in 1..256,
    do: :ok

  defp validate_actor(_actor_ref), do: {:error, :credential_actor_invalid}

  defp root_key do
    case Config.fetch_env(:credential_key) do
      {:ok, key} when is_binary(key) and byte_size(key) == 32 -> key
      _missing_or_invalid -> raise "RYKER_CREDENTIAL_KEY is missing or invalid"
    end
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Delivers `{:credentials_changed, kind, name}` after a credential is stored,
  verified or deleted, and its transaction committed. The payload names the
  credential, never its value. The runtime owner reassembles what uses it; a
  page that shows whether a credential is configured or verified redraws.
  """
  def subscribe, do: Ryker.PubSub.subscribe(topic())

  @doc "Stops the announcements `subscribe/0` started."
  def unsubscribe, do: Ryker.PubSub.unsubscribe(topic())

  defp topic, do: "credentials"

  defp broadcast_credentials_changed(kind, name) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(topic(), {:credentials_changed, kind, name})
    end)
  end
end
