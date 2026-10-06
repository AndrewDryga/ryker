defmodule Ryker.ControlPlane.CloudflareAccess do
  @moduledoc """
  Who Cloudflare Access let in to the console.

  An install published through Cloudflare Access, a tunnel to the console with
  an Access application in front, gets every request with the signed-in
  person's token in `Cf-Access-Jwt-Assertion` (Andrew, 2026-10-04: two client
  teams sign in with Google rather than join his tailnet). Ryker
  names that person only after checking the token the way Cloudflare asks an
  origin to: an RS256 signature by a key the team publishes at
  `https://<team domain>/cdn-cgi/access/certs`, the application's audience tag,
  the team as its issuer, and a lifetime that includes now.

  The keys are read on first use and again once an hour, keeping only the keys
  the team publishes then: kept until a restart, a key Cloudflare had retired
  still signed for the console (2026-10-04 review). Cloudflare publishes its
  next key before signing with it, so a token naming a key Ryker has not seen
  reads them again, at most once a minute.
  """

  alias Ryker.ControlPlane.Viewer
  alias Ryker.Delivery.HTTPClient

  @certs_path "/cdn-cgi/access/certs"
  @refresh_seconds 60
  @keys_seconds 3_600
  @leeway_seconds 60
  @maximum_token_bytes 8_192
  @maximum_login_bytes 200
  @maximum_certs_bytes 65_536
  @signed_in :ryker_cloudflare_access_viewer

  @type config :: %{
          required(:team_domain) => String.t(),
          required(:audience) => String.t(),
          optional(:certs) => (String.t() -> {:ok, map()} | :error)
        }

  @doc """
  The person a request's Access token names, until the moment the token stops
  counting, or `:error` without a valid one.
  """
  @spec viewer(Plug.Conn.t(), config()) :: {:ok, Viewer.t()} | :error
  def viewer(%Plug.Conn{private: %{@signed_in => viewer}}, _config), do: {:ok, viewer}

  def viewer(conn, config) do
    with [token] <- Plug.Conn.get_req_header(conn, "cf-access-jwt-assertion"),
         {:ok, %{"email" => email, "exp" => expires}} <- verify(token, config),
         true <- login?(email) do
      {:ok, %{login: email, name: email, via: :cloudflare, until: expires + @leeway_seconds}}
    else
      _invalid -> :error
    end
  end

  @doc """
  The request, carrying the person its token named once the guard checked it
  (`Ryker.ControlPlane.BrowserGuard`), so no later step checks it again.
  """
  @spec signed_in(Plug.Conn.t(), Viewer.t()) :: Plug.Conn.t()
  def signed_in(conn, viewer), do: Plug.Conn.put_private(conn, @signed_in, viewer)

  @doc "The claims of a token Access signed for this application, or `:error`."
  @spec verify(String.t(), config()) :: {:ok, map()} | :error
  def verify(token, %{team_domain: team, audience: audience} = config)
      when is_binary(token) and byte_size(token) <= @maximum_token_bytes do
    with [header, claims, signature] <- String.split(token, "."),
         {:ok, %{"alg" => "RS256", "kid" => kid}} <- decode(header),
         {:ok, signature} <- Base.url_decode64(signature, padding: false),
         {:ok, key} <- key(config, kid),
         true <- :public_key.verify(header <> "." <> claims, :sha256, signature, key),
         {:ok, claims} <- decode(claims),
         true <- current?(claims, team, audience) do
      {:ok, claims}
    else
      _invalid -> :error
    end
  end

  def verify(_token, _config), do: :error

  defp current?(claims, team, audience) do
    now = System.os_time(:second)

    claims["iss"] == "https://" <> team and audience in List.wrap(claims["aud"]) and
      is_integer(claims["exp"]) and now <= claims["exp"] + @leeway_seconds and
      (not Map.has_key?(claims, "nbf") or
         (is_integer(claims["nbf"]) and claims["nbf"] - @leeway_seconds <= now))
  end

  defp login?(email),
    do:
      is_binary(email) and byte_size(email) in 3..@maximum_login_bytes and String.valid?(email) and
        Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/u, email)

  defp decode(segment) do
    with {:ok, json} <- Base.url_decode64(segment, padding: false),
         {:ok, %{} = value} <- Jason.decode(json) do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  # --- the team's keys -------------------------------------------------------

  defp key(%{team_domain: team} = config, kid) do
    cached = :persistent_term.get({__MODULE__, team}, nil)
    now = System.monotonic_time(:second)

    cond do
      fresh?(cached, now) and Map.has_key?(cached.keys, kid) -> Map.fetch(cached.keys, kid)
      fresh?(cached, now) and now - cached.read_at < @refresh_seconds -> :error
      true -> reread(config, kid, cached, now)
    end
  end

  defp fresh?(nil, _now), do: false
  defp fresh?(cached, now), do: now - cached.read_at < @keys_seconds

  # The keys the team publishes now replace the ones kept, so a retired key is
  # dropped; while they cannot be read the ones kept still serve.
  defp reread(%{team_domain: team} = config, kid, cached, now) do
    keys =
      case read_certs(config) do
        {:ok, keys} -> keys
        :error -> (cached && cached.keys) || %{}
      end

    :persistent_term.put({__MODULE__, team}, %{keys: keys, read_at: now})
    Map.fetch(keys, kid)
  end

  defp read_certs(%{team_domain: team} = config) do
    certs = Map.get(config, :certs, &fetch_certs/1)

    case certs.(team) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok,
         for(
           %{"kid" => kid} = jwk <- keys,
           {:ok, key} <- [rsa_key(jwk)],
           into: %{},
           do: {kid, key}
         )}

      _unreadable ->
        :error
    end
  end

  defp rsa_key(%{"kty" => "RSA", "n" => modulus, "e" => exponent}) do
    with {:ok, modulus} <- Base.url_decode64(modulus, padding: false),
         {:ok, exponent} <- Base.url_decode64(exponent, padding: false) do
      {:ok, {:RSAPublicKey, :binary.decode_unsigned(modulus), :binary.decode_unsigned(exponent)}}
    end
  end

  defp rsa_key(_jwk), do: :error

  defp fetch_certs(team) do
    request = HTTPClient.build(:get, "https://" <> team <> @certs_path)

    with {:ok, %{status: 200, body: body}} <-
           HTTPClient.stream(request, Ryker.CoopFinch, 5_000, @maximum_certs_bytes),
         {:ok, %{} = certs} <- Jason.decode(body) do
      {:ok, certs}
    else
      _unavailable -> :error
    end
  end
end
