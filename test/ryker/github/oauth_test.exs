defmodule Ryker.GitHub.OAuthTest do
  use ExUnit.Case, async: true
  alias Ryker.Crypto
  alias Ryker.GitHub.OAuth

  defmodule Transport do
    def stream(request, owner, 15_000, 16_384) do
      send(owner, {:exchange, request})
      {:ok, %{status: 200, body: ~s({"access_token":"user-token-example","token_type":"bearer"})}}
    end
  end

  setup do
    config = %{
      client_id: "Iv1.example",
      client_secret: "client-secret-example",
      web_url: "https://github.com",
      callback_url: "https://ryker.example/github/actions/callback"
    }

    %{config: config}
  end

  test "sign-in binds the exchange to one browser and the registered callback", %{config: config} do
    {url, challenge} = OAuth.begin(config, "/github/actions/review/example", 1000)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    digest = Crypto.sha256(challenge["verifier"])
    assert query["code_challenge"] == Base.url_encode64(digest, padding: false)
    assert query["code_challenge_method"] == "S256"
    assert query["state"] == challenge["state"]
    assert query["redirect_uri"] == config.callback_url
    refute Map.has_key?(query, "client_secret")
    params = %{"state" => challenge["state"], "code" => "one-use-code"}

    assert OAuth.finish(config, challenge, params, 1001, transport: Transport, finch: self()) ==
             {:ok, "user-token-example"}

    assert_received {:exchange, request}
    body = URI.decode_query(request.body)
    assert body["code_verifier"] == challenge["verifier"]
    assert body["client_secret"] == config.client_secret
    assert body["redirect_uri"] == config.callback_url
  end

  test "expired and mismatched browser challenges never exchange a code", %{config: config} do
    {_url, challenge} = OAuth.begin(config, "/github/actions/review/example", 1000)
    params = %{"state" => "another-browser", "code" => "one-use-code"}

    assert OAuth.finish(config, challenge, params, 1001, transport: Transport, finch: self()) ==
             {:error, :sign_in_expired}

    params = %{params | "state" => challenge["state"]}

    assert OAuth.finish(config, challenge, params, 1600, transport: Transport, finch: self()) ==
             {:error, :sign_in_expired}

    assert OAuth.finish(config, %{}, params, 1001, transport: Transport, finch: self()) ==
             {:error, :sign_in_expired}

    refute_received {:exchange, _request}
  end
end
