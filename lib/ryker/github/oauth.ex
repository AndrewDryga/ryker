defmodule Ryker.GitHub.OAuth do
  @moduledoc "GitHub App user sign-in, with state and PKCE bound to one browser."
  alias Ryker.Crypto
  alias Ryker.Delivery

  @headers [{"accept", "application/json"}, {"content-type", "application/x-www-form-urlencoded"}]
  @lifetime 600

  @doc "Starts a ten-minute sign-in. Keep the returned challenge in an encrypted cookie."
  @spec begin(map(), String.t(), integer()) :: {String.t(), map()}
  def begin(config, return_path, now) do
    verifier = Crypto.random_secret(32)
    state = Crypto.random_secret(32)
    digest = Crypto.sha256(verifier)
    challenge = Base.url_encode64(digest, padding: false)

    query =
      URI.encode_query(%{
        "client_id" => config.client_id,
        "redirect_uri" => config.callback_url,
        "state" => state,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    {config.web_url <> "/login/oauth/authorize?" <> query,
     %{
       "state" => state,
       "verifier" => verifier,
       "return_path" => return_path,
       "expires_at" => now + @lifetime
     }}
  end

  @doc "Checks the browser challenge before exchanging a code. Provider error bodies never escape."
  @spec finish(map(), map(), map(), integer(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def finish(config, challenge, params, now, options \\ []) do
    with :ok <- check_challenge(challenge, params, now),
         do: exchange(config, params["code"], challenge["verifier"], options)
  end

  defp check_challenge(
         %{"state" => expected, "expires_at" => expires, "verifier" => verifier},
         %{"state" => state, "code" => code},
         now
       )
       when is_binary(expected) and is_binary(state) and is_binary(verifier) and
              is_binary(code) and byte_size(code) in 1..1024 and is_integer(expires) and
              expires > now and expires <= now + @lifetime do
    if Plug.Crypto.secure_compare(expected, state), do: :ok, else: {:error, :sign_in_expired}
  end

  defp check_challenge(_challenge, _params, _now), do: {:error, :sign_in_expired}

  defp exchange(config, code, verifier, options) do
    body =
      URI.encode_query(%{
        "client_id" => config.client_id,
        "client_secret" => config.client_secret,
        "redirect_uri" => config.callback_url,
        "code" => code,
        "code_verifier" => verifier
      })

    url = config.web_url <> "/login/oauth/access_token"
    request = Delivery.HTTPClient.build(:post, url, @headers, body)
    transport = Keyword.get(options, :transport, Delivery.HTTPClient)
    finch = Keyword.get(options, :finch, Ryker.CoopFinch)

    with {:ok, %{status: 200, body: response}} <- transport.stream(request, finch, 15_000, 16_384),
         {:ok, %{"access_token" => token, "token_type" => "bearer"}} <- Jason.decode(response),
         true <- is_binary(token) and byte_size(token) in 8..4096 do
      {:ok, token}
    else
      _refused -> {:error, :sign_in_failed}
    end
  end
end
