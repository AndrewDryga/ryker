defmodule Ryker.CoopFleet.ModelAccountProvider do
  @moduledoc false
  alias Ryker.Delivery

  @codex_client "app_EMoamEEZ73f0CkXaXp7hrann"
  @claude_client "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  def import_native("codex", %{"auth.json" => raw} = files) when map_size(files) == 1 do
    with {:ok, %{"auth_mode" => "chatgpt", "tokens" => tokens}} <- Jason.decode(raw),
         {:ok, access} <- claims(tokens["access_token"]),
         {:ok, identity} <- claims(tokens["id_token"]),
         account when is_binary(account) <-
           tokens["account_id"] || auth(identity)["chatgpt_account_id"],
         user when is_binary(user) <- auth(identity)["chatgpt_user_id"] || identity["sub"],
         true <- account != "" and user != "",
         true <-
           consistent?(auth(identity), account, user) and consistent?(auth(access), account, user),
         {:ok, expires} <- DateTime.from_unix(access["exp"]) do
      {:ok,
       %{
         "version" => 1,
         "provider" => "codex",
         "selection" => "chatgpt",
         "credential" => tokens["access_token"],
         "refresh_token" => tokens["refresh_token"],
         "id_token" => tokens["id_token"],
         "account_id" => account,
         "principal" => account <> ":" <> user,
         "expires_at" => DateTime.to_iso8601(expires)
       }}
    else
      _invalid -> {:error, :invalid_native_model_account}
    end
  rescue
    _invalid -> {:error, :invalid_native_model_account}
  end

  def import_native(
        "claude",
        %{".credentials.json" => raw, ".claude.json" => identity_raw} = files
      )
      when map_size(files) == 2 do
    with {:ok, %{"claudeAiOauth" => grant}} <- Jason.decode(raw),
         {:ok, %{"oauthAccount" => identity}} <- Jason.decode(identity_raw),
         account when is_binary(account) <- identity["accountUuid"],
         organization when is_binary(organization) <- identity["organizationUuid"],
         true <- account != "" and organization != "",
         scopes when is_list(scopes) <- grant["scopes"],
         true <- "user:inference" in scopes,
         {:ok, expires} <- DateTime.from_unix(grant["expiresAt"], :millisecond) do
      {:ok,
       %{
         "version" => 1,
         "provider" => "claude",
         "selection" => "claude-oauth",
         "credential" => grant["accessToken"],
         "refresh_token" => grant["refreshToken"],
         "principal" => account <> ":" <> organization,
         "scopes" => scopes,
         "expires_at" => DateTime.to_iso8601(expires)
       }}
    else
      _invalid -> {:error, :invalid_native_model_account}
    end
  rescue
    _invalid -> {:error, :invalid_native_model_account}
  end

  def import_native(_provider, _files), do: {:error, :invalid_native_model_account}

  def refresh(document, stream \\ &Delivery.HTTPClient.stream/4) do
    {url, body} = request(document)
    encoded = Jason.encode!(body)

    request =
      Delivery.HTTPClient.build(:post, url, [{"content-type", "application/json"}], encoded)

    case stream.(request, Ryker.CoopFinch, 20_000, 64 * 1_024) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status, body: body}} when status in [400, 401, 403] ->
        if renewal_refused?(status, body), do: {:error, :refused}, else: {:error, :uncertain}

      {:ok, %{status: status}} when status >= 500 or status == 429 ->
        {:error, :retry_later}

      _unsettled ->
        {:error, :uncertain}
    end
  end

  defp renewal_refused?(status, raw) when status in [400, 401] do
    case Jason.decode(raw) do
      {:ok, response} when is_map(response) ->
        nested = response["error"]

        codes =
          [response["code"]] ++
            if(is_map(nested), do: [nested["code"], nested["type"]], else: [nested])

        Enum.any?(
          codes,
          &(&1 in ~w(invalid_grant refresh_token_expired refresh_token_reused refresh_token_invalidated))
        )

      _invalid ->
        false
    end
  end

  defp renewal_refused?(_status, _raw), do: false

  def complete(%{"provider" => "codex"} = before, raw, now) do
    with {:ok, response} when is_map(response) <- Jason.decode(raw),
         access when is_binary(access) <- response["access_token"],
         true <-
           Ryker.Maps.optional_string?(response, "refresh_token") and
             Ryker.Maps.optional_string?(response, "id_token"),
         {:ok, next} <-
           import_native("codex", %{
             "auth.json" =>
               Jason.encode!(%{
                 "auth_mode" => "chatgpt",
                 "tokens" => %{
                   "access_token" => access,
                   "refresh_token" =>
                     replacement(response["refresh_token"], before["refresh_token"]),
                   "id_token" => replacement(response["id_token"], before["id_token"]),
                   "account_id" => before["account_id"]
                 }
               })
           }),
         true <- next["principal"] == before["principal"],
         {:ok, expires, _offset} <- DateTime.from_iso8601(next["expires_at"]),
         true <- DateTime.compare(expires, now) == :gt do
      {:ok, Map.merge(before, next) |> Map.delete("renewal")}
    else
      _invalid -> {:error, :invalid_issued_model_credential}
    end
  end

  def complete(%{"provider" => "claude"} = before, raw, now) do
    with {:ok, response} when is_map(response) <- Jason.decode(raw),
         access when is_binary(access) and byte_size(access) >= 8 <- response["access_token"],
         seconds when is_integer(seconds) and seconds > 0 <- response["expires_in"],
         true <- Ryker.Maps.optional_string?(response, "refresh_token"),
         {:ok, scopes} <- issued_scopes(response, before["scopes"]),
         expires <- DateTime.add(now, seconds, :second) do
      {:ok,
       before
       |> Map.put("credential", access)
       |> Map.put(
         "refresh_token",
         replacement(response["refresh_token"], before["refresh_token"])
       )
       |> Map.put("expires_at", DateTime.to_iso8601(expires))
       |> Map.put("scopes", scopes)
       |> Map.delete("renewal")}
    else
      _invalid -> {:error, :invalid_issued_model_credential}
    end
  rescue
    _invalid -> {:error, :invalid_issued_model_credential}
  end

  defp issued_scopes(%{"scope" => value}, _previous) when is_binary(value) do
    scopes = String.split(value)
    if "user:inference" in scopes, do: {:ok, scopes}, else: {:error, :invalid_issued_scopes}
  end

  defp issued_scopes(response, previous) do
    if Map.has_key?(response, "scope"),
      do: {:error, :invalid_issued_scopes},
      else: {:ok, previous}
  end

  defp request(%{"provider" => "codex"} = doc) do
    {"https://auth.openai.com/oauth/token",
     %{
       "grant_type" => "refresh_token",
       "refresh_token" => doc["refresh_token"],
       "client_id" => @codex_client
     }}
  end

  defp request(%{"provider" => "claude"} = doc) do
    {"https://platform.claude.com/v1/oauth/token",
     %{
       "grant_type" => "refresh_token",
       "refresh_token" => doc["refresh_token"],
       "client_id" => @claude_client,
       "scope" => Enum.join(doc["scopes"], " ")
     }}
  end

  defp claims(token) when is_binary(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, raw} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(raw) do
      {:ok, claims}
    else
      _invalid -> {:error, :invalid_native_claims}
    end
  end

  defp claims(_invalid), do: {:error, :invalid_native_claims}
  defp auth(claims), do: claims["https://api.openai.com/auth"] || %{}

  defp consistent?(identity, account, user) do
    identity["chatgpt_account_id"] in [nil, "", account] and
      identity["chatgpt_user_id"] in [nil, "", user]
  end

  defp replacement(value, previous) when value in [nil, ""], do: previous
  defp replacement(value, _previous), do: value
end
