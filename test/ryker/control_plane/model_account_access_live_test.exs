defmodule Ryker.ControlPlane.ModelAccountAccessLiveTest do
  use Ryker.DataCase, async: false
  import Ryker.ConsoleSignIn, only: [signed_in_conn: 0]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.{Config, Credentials, Settings}
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.CoopFleet.ModelAccounts
  @endpoint Endpoint
  @actor "control-plane:local"
  setup do
    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub,
       live_view: [signing_salt: "settings-worker-jobs-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    {:ok, _snapshot} = Settings.initialize(@actor)
    Config.put_override(:credential_key, :binary.copy(<<41>>, 32))
    :ok
  end

  test "a saved account accepts a key without returning it to the browser, and removal asks first" do
    {:ok, view, _html} = open("codex@default")
    view |> element("#model-access-kind") |> render_change(%{"kind" => "apikey"})
    assert has_element?(view, "#model-key-form")
    refute has_element?(view, "#model-access-remove")

    view
    |> form("#model-key-form", %{"credential" => %{"secret" => "controller-only-key-canary"}})
    |> render_submit()

    assert_patch(view, "/settings/models")
    refute render(view) =~ "controller-only-key-canary"
    {:ok, document} = ModelAccounts.current("codex", "default")
    assert document["credential"] == "controller-only-key-canary"
    assert {:ok, encoded} = Credentials.fetch(:model_account, "codex:default")
    assert encoded =~ "controller-only-key-canary"
    {:ok, again, _html} = open("codex@default")
    assert has_element?(again, "#model-access-remove")
    refute render(again) =~ "controller-only-key-canary"
    again |> element("#model-access-remove button") |> render_click()
    assert has_element?(again, "#remove-model-access")
    assert {:ok, _} = ModelAccounts.current("codex", "default")
    again |> element("#remove-model-access button[phx-click=remove]") |> render_click()
    assert_patch(again, "/settings/models")
    assert ModelAccounts.current("codex", "default") == {:error, :model_account_unavailable}
  end

  test "request concurrency is shared by account aliases and invalid input leaves the limit intact" do
    {:ok, _} = ModelAccounts.put_key("codex@default", "capacity-controller-key", @actor)
    {:ok, view, _} = open("codex@default")
    assert has_element?(view, "#model-concurrency-form")
    view |> form("#model-concurrency-form", %{"concurrency" => "3"}) |> render_submit()
    assert {:ok, %{concurrency: 3}} = Ryker.CoopFleet.model_capacity("codex@default")
    view |> form("#model-concurrency-form", %{"concurrency" => "300"}) |> render_submit()
    assert has_element?(view, "#model-capacity-error")
    assert {:ok, %{concurrency: 3}} = Ryker.CoopFleet.model_capacity("codex@default")
    view |> form("#model-concurrency-form", %{"concurrency" => "0"}) |> render_submit()
    assert {:ok, %{concurrency: 0}} = Ryker.CoopFleet.model_capacity("codex@default")
    refute render(view) =~ "capacity-controller-key"
  end

  test "unknown accounts do not expose credential forms" do
    {:ok, view, _html} = open("codex@missing")
    refute has_element?(view, "#model-key-form")
    assert render(view) =~ "model account"
  end

  test "invalid key remains absent from the rendered error" do
    {:ok, view, _html} = open("codex@default")
    view |> element("#model-access-kind") |> render_change(%{"kind" => "apikey"})
    view |> form("#model-key-form", %{"credential" => %{"secret" => "bad"}}) |> render_submit()
    assert has_element?(view, "#model-access-error")
    refute has_element?(view, "input[value=bad]")
    assert ModelAccounts.current("codex", "default") == {:error, :model_account_unavailable}
  end

  test "an operator can resume a Coop import, correct a bad paste and store a bundle only once" do
    ref = "codex@default"
    {:ok, view, _} = open(ref)
    view |> element("#model-access-kind") |> render_change(%{"kind" => "transfer"})
    view |> element("button[phx-click=receive-code]") |> render_click()
    {:ok, code} = Ryker.CoopFleet.model_receive_code(ref, @actor)
    assert render(view) =~ code
    form(view, "#model-transfer-form", secret_bundle: "incomplete") |> render_submit()
    assert has_element?(view, "#model-transfer-error")
    assert Ryker.CoopFleet.model_receive_code(ref, @actor) == {:ok, code}

    bundle =
      encrypt_for(code, %{
        "provider" => "codex",
        "account" => "default",
        "api_key" => "imported-key-canary",
        "id" => "00112233445566778899aabbccddeeff"
      })

    form(view, "#model-transfer-form", secret_bundle: bundle) |> render_submit()
    assert_patch(view, "/settings/models")

    assert {:ok, %{"credential" => "imported-key-canary"}} =
             ModelAccounts.current("codex", "default")

    assert ModelAccounts.remove_account(ref, @actor) == :ok
    assert {:error, _} = Ryker.CoopFleet.receive_model_account(ref, ref, bundle, @actor)
  end

  defp encrypt_for("coop-import-1." <> encoded = code, payload) do
    b64 = &Base.url_encode64(&1, padding: false)
    %{"key" => der} = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
    pub = :public_key.der_decode(:RSAPublicKey, Base.url_decode64!(der, padding: false))
    key = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(12)

    protected =
      b64.(
        Jason.encode!(%{
          "alg" => "RSA-OAEP-256",
          "enc" => "A256GCM",
          "kid" => b64.(Ryker.Crypto.sha256(code))
        })
      )

    wrapped =
      :public_key.encrypt_public(key, pub,
        rsa_padding: :rsa_pkcs1_oaep_padding,
        rsa_oaep_md: :sha256,
        rsa_mgf1_md: :sha256
      )

    {cipher, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        Jason.encode!(payload),
        protected,
        true
      )

    Enum.join([protected | Enum.map([wrapped, nonce, cipher, tag], b64)], ".")
  end

  defp open(account) do
    live(
      signed_in_conn() |> Map.put(:host, "localhost"),
      "/settings/models/accounts/" <> URI.encode_www_form(account) <> "/edit"
    )
  end
end
