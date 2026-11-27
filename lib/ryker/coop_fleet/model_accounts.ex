defmodule Ryker.CoopFleet.ModelAccounts do
  @moduledoc "Controller custody for provider accounts used by remote Coop runs."
  alias Ryker.{AdvisoryLock, Config, Credentials, Crypto, Maps, Repo, Settings}
  alias Ryker.CoopFleet.ModelAccountProvider

  @required ~w(version provider selection credential)
  @optional ~w(refresh_token expires_at account_id principal scopes id_token)

  def put_key(reference, secret, actor) do
    with {:ok, provider, account} <- identity(reference) do
      put(
        provider,
        account,
        %{
          "version" => 1,
          "provider" => provider,
          "selection" => "apikey",
          "credential" => secret
        },
        actor
      )
    end
  end

  def import_account(reference, files, actor) do
    with {:ok, provider, account} <- identity(reference),
         do: import_native(provider, account, files, actor)
  end

  def remove_account(reference, actor) do
    with {:ok, provider, account} <- identity(reference), do: remove(provider, account, actor)
  end

  defp identity(reference) do
    if Settings.Work.account?(reference) do
      [provider, account] = String.split(reference, "@", parts: 2)
      {:ok, provider, account}
    else
      {:error, :invalid_model_account}
    end
  end

  @doc "Configured account access, without refreshing or returning provider credentials."
  def statuses(workspace_ref \\ nil) do
    with {:ok, snapshot} <- Settings.fetch(),
         true <- is_nil(workspace_ref) or snapshot.work.workspace_ref == workspace_ref do
      {:ok, Map.new(snapshot.work.model_accounts, &{&1, status(&1)})}
    else
      false -> {:error, :model_workspace_not_configured}
      error -> error
    end
  end

  def status(reference) do
    with {:ok, provider, account} <- identity(reference),
         %{status: :configured} <- Credentials.status(:model_account, name(provider, account)),
         {:ok, document} <- read(provider, account) do
      %{state: access_state(document), method: document["selection"]}
    else
      %{status: :missing} -> %{state: :missing}
      _unavailable -> %{state: :unavailable}
    end
  end

  defp access_state(
         %{"provider" => provider, "renewal" => %{"response" => raw, "received_at" => received}} =
           doc
       ) do
    case complete_issued(provider, doc, raw, received) do
      {:ok, next} -> access_state(next)
      _invalid -> :needs_reconciliation
    end
  end

  defp access_state(%{"renewal" => %{"state" => "refused"}}), do: :refused

  defp access_state(%{"renewal" => %{"state" => "started", "deadline" => deadline}} = doc) do
    if deadline <= DateTime.to_unix(Repo.now!()) and not get_in(doc, ["renewal", "response"]),
      do: :needs_reconciliation,
      else: :configured
  end

  defp access_state(document) do
    if usable(document) == :ok or token?(document["refresh_token"]),
      do: :configured,
      else: :expired
  end

  @doc false
  def quota_identity(document) do
    principal =
      if document["selection"] == "apikey",
        do: document["credential"],
        else: document["principal"]

    payload = Jason.encode!([document["provider"], document["selection"], principal])

    Config.fetch_env!(:credential_key)
    |> Crypto.hmac_sha256(["coop-model-quota-v1", <<0>>, payload])
    |> Base.encode16(case: :lower)
  end

  @doc false
  def fetch_quota_identity(reference) do
    with {:ok, provider, account} <- identity(reference),
         {:ok, document} <- read(provider, account) do
      {:ok,
       %{
         id: quota_identity(document),
         epoch: document["epoch"],
         provider: provider,
         account: account
       }}
    end
  end

  @doc "Store a provider account on the controller and revoke its previous epoch."
  def put(provider, account, document, actor)
      when is_binary(provider) and is_binary(account) and is_map(document) do
    with true <- Settings.Work.account?(provider <> "@" <> account),
         true <- Maps.exact_keys?(document, @required, @optional),
         true <- valid?(provider, document) do
      epoch = :binary.decode_unsigned(Crypto.random_bytes(7)) + 1
      value = document |> Map.put("epoch", epoch) |> Jason.encode!()

      Repo.transaction(fn ->
        AdvisoryLock.hold!("model-account:" <> name(provider, account))

        write_result!(Credentials.put(:model_account, name(provider, account), value, actor))
      end)
    else
      _invalid -> {:error, :invalid_model_account}
    end
  end

  def put(_provider, _account, _document, _actor), do: {:error, :invalid_model_account}

  def metadata(provider, account) do
    with {:ok, document} <- prepare(provider, account) do
      {:ok, Map.take(document, ~w(provider selection epoch account_id expires_at))}
    end
  end

  defp import_native(provider, account, files, actor) do
    with {:ok, document} <- ModelAccountProvider.import_native(provider, files),
         do: put(provider, account, document, actor)
  end

  def remove(provider, account, actor) do
    with {:ok, :ok} <-
           Repo.transaction(fn ->
             AdvisoryLock.hold!("model-account:" <> name(provider, account))

             write_result!(Credentials.delete(:model_account, name(provider, account), actor))
           end),
         do: :ok
  end

  defp write_result!({:ok, value}), do: value
  defp write_result!(:ok), do: :ok
  defp write_result!({:error, reason}), do: Repo.rollback(reason)

  @doc false
  def current(provider, account) do
    with {:ok, document} <- read(provider, account),
         false <- get_in(document, ["renewal", "state"]) == "refused",
         :ok <- usable(document) do
      {:ok, document}
    else
      true -> {:error, :model_account_refused}
      error -> error
    end
  end

  @doc "Prepare the current controller access while retaining rotating renewal responses."
  def prepare(provider, account, requester \\ &ModelAccountProvider.refresh/1) do
    case locked(provider, account, &begin_refresh(provider, account, &1)) do
      {:ok, {:ready, document}} ->
        usable_result(document)

      {:ok, {:request, document, nonce}} ->
        result = requester.(document)

        result =
          locked(
            provider,
            account,
            &retain_refresh(provider, account, &1, document["epoch"], nonce, result)
          )

        finish_refresh(result, provider, account, requester)

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_refresh({:ok, {:ready, next}}, provider, account, requester) do
    if get_in(next, ["renewal", "response"]),
      do: prepare(provider, account, requester),
      else: usable_result(next)
  end

  defp finish_refresh({:ok, {:error, reason}}, _provider, _account, _requester),
    do: {:error, reason}

  defp finish_refresh({:error, reason}, _provider, _account, _requester), do: {:error, reason}

  defp locked(provider, account, function) do
    Repo.transaction(fn ->
      AdvisoryLock.hold!("model-account:" <> name(provider, account))

      case read(provider, account) do
        {:ok, document} -> function.(document)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp begin_refresh(provider, account, document) do
    now = Repo.now!()

    case document["renewal"] do
      %{"response" => raw, "received_at" => received_at} ->
        case complete_issued(provider, document, raw, received_at) do
          {:ok, next} -> {:ready, save!(provider, account, next)}
          _invalid -> {:error, :model_issued_response_needs_reconciliation}
        end

      %{"state" => "refused"} ->
        {:error, :model_account_refused}

      %{"state" => "started", "deadline" => deadline} ->
        if deadline > DateTime.to_unix(now),
          do: {:ready, document},
          else: {:error, :model_renewal_needs_reconciliation}

      _ready ->
        if refresh_due?(document, now) do
          nonce = Crypto.random_hex(16)

          renewal = %{
            "state" => "started",
            "nonce" => nonce,
            "deadline" => DateTime.to_unix(now) + 30
          }

          next = save!(provider, account, Map.put(document, "renewal", renewal))
          {:request, next, nonce}
        else
          {:ready, document}
        end
    end
  end

  defp complete_issued(provider, document, raw, received) do
    with {:ok, at, _offset} <- DateTime.from_iso8601(received),
         {:ok, next} <- ModelAccountProvider.complete(document, raw, at),
         true <- valid?(provider, next) do
      {:ok, next}
    else
      _invalid -> {:error, :invalid_issued_model_credential}
    end
  end

  defp retain_refresh(provider, account, current, epoch, nonce, result) do
    if current["epoch"] == epoch and get_in(current, ["renewal", "nonce"]) == nonce do
      case result do
        {:ok, raw} when is_binary(raw) and byte_size(raw) <= 64 * 1_024 ->
          # Commit the provider's successful response before parsing it. A
          # subsequent prepare completes these exact issued bytes after a crash.
          renewal =
            current["renewal"]
            |> Map.put("response", raw)
            |> Map.put("received_at", DateTime.to_iso8601(Repo.now!()))

          next = save!(provider, account, Map.put(current, "renewal", renewal))
          {:ready, next}

        {:error, :retry_later} ->
          next =
            current
            |> Map.delete("renewal")
            |> Map.put("retry_after", DateTime.to_unix(Repo.now!()) + 30)

          {:ready, save!(provider, account, next)}

        {:error, :refused} ->
          next = put_in(current, ["renewal", "state"], "refused")
          save!(provider, account, next)
          {:error, :model_account_refused}

        _uncertain ->
          {:error, :model_renewal_needs_reconciliation}
      end
    else
      {:error, :model_account_changed}
    end
  end

  defp refresh_due?(%{"selection" => "apikey"}, _now), do: false

  defp refresh_due?(document, now) do
    {:ok, expires, _offset} = DateTime.from_iso8601(document["expires_at"])

    DateTime.diff(expires, now, :second) <= 600 and
      Map.get(document, "retry_after", 0) <= DateTime.to_unix(now)
  end

  defp save!(provider, account, document) do
    case Credentials.put(
           :model_account,
           name(provider, account),
           Jason.encode!(document),
           "system:model-renewal"
         ) do
      {:ok, _metadata} -> document
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp usable_result(document) do
    with :ok <- usable(document), do: {:ok, document}
  end

  defp read(provider, account) do
    with true <- Settings.Work.account?(provider <> "@" <> account),
         {:ok, raw} <- Credentials.fetch(:model_account, name(provider, account)),
         {:ok, document} <- Jason.decode(raw),
         true <- valid?(provider, document),
         epoch when is_integer(epoch) and epoch > 0 <- document["epoch"] do
      {:ok, document}
    else
      _unavailable -> {:error, :model_account_unavailable}
    end
  end

  defp valid?(provider, %{"version" => 1, "provider" => provider, "selection" => selection} = doc)
       when provider in ["claude", "codex"] do
    selections =
      if provider == "claude", do: ["apikey", "claude-oauth"], else: ["apikey", "chatgpt"]

    selection in selections and token?(doc["credential"]) and
      (selection == "apikey" or oauth?(provider, doc))
  end

  defp valid?(_provider, _document), do: false

  defp oauth?(provider, doc) do
    token?(doc["refresh_token"]) and bounded_string?(doc["principal"], 512) and
      valid_expiry?(doc["expires_at"]) and oauth_identity?(provider, doc)
  end

  defp bounded_string?(value, maximum), do: is_binary(value) and byte_size(value) in 1..maximum

  defp valid_expiry?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_expiry?(_value), do: false

  defp oauth_identity?("codex", doc),
    do: token?(doc["id_token"]) and bounded_string?(doc["account_id"], 512)

  defp oauth_identity?("claude", doc) do
    is_list(doc["scopes"]) and Enum.all?(doc["scopes"], &is_binary/1) and
      "user:inference" in doc["scopes"]
  end

  defp usable(%{"selection" => "apikey"}), do: :ok

  defp usable(document) do
    with {:ok, expires, _} <- DateTime.from_iso8601(document["expires_at"]),
         true <- DateTime.compare(expires, Repo.now!()) == :gt do
      :ok
    else
      _expired -> {:error, :model_access_expired}
    end
  end

  defp token?(value) do
    is_binary(value) and byte_size(value) in 8..8192 and
      String.valid?(value) and :binary.match(value, ["\r", "\n", <<0>>]) == :nomatch
  end

  defp name(provider, account), do: provider <> ":" <> account
end
