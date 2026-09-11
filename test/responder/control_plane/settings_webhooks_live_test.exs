defmodule Responder.ControlPlane.SettingsWebhooksLiveTest do
  use Responder.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Responder.ControlPlane.{Actions, Endpoint, Projection}
  alias Responder.Ingress.Inbox
  alias Responder.Settings
  alias Responder.Webhooks.Presets

  @endpoint Endpoint
  @actor "control-plane:local"
  @registered "ALERTMANAGER_WEBHOOK_SECRET"
  @other "DEPLOYMENT_WEBHOOK_SECRET"

  setup do
    System.put_env("RESPONDER_WEBHOOK_SECRET_NAMES", "#{@registered},#{@other}")
    on_exit(fn -> System.delete_env("RESPONDER_WEBHOOK_SECRET_NAMES") end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Responder.ControlPlane.PubSub,
       live_view: [signing_salt: "settings-webhooks-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    :ok
  end

  test "a source may only reference a credential this deployment registered" do
    # Accepting any name here would make the form a way to read the process
    # environment, and would save a route that can never start.
    installation!()
    {:ok, view, _html} = open()

    assert has_element?(view, "#settings-webhooks-secret_name option[value='#{@registered}']")
    refute has_element?(view, "#settings-webhooks-secret_name option[value='SLACK_BOT_TOKEN']")

    revision = Settings.fetch!().installation.revision

    assert {:error, {:invalid_settings, [{:secret_name, :unregistered_secret}]}} =
             Actions.callbacks().put_settings_item.(
               :webhooks,
               Map.put(source_params(), "secret_name", "SLACK_BOT_TOKEN"),
               revision
             )

    assert Settings.fetch!().webhook_sources == []
  end

  test "a custom mapping is saved as bounded paths and its required fields are named" do
    installation!()
    {:ok, view, _html} = open()

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{
        "adapter_kind" => "mapped_json",
        "mapping" => %{"status" => "state", "title" => "subject"}
      })
    )
    |> render_submit()

    assert has_element?(view, ".settings-error", "Custom field mapping")
    assert Settings.fetch!().webhook_sources == []

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{
        "adapter_kind" => "mapped_json",
        "mapping" => %{"event_id" => "id", "status" => "state", "title" => "subject"}
      })
    )
    |> render_submit()

    assert [source] = Settings.fetch!().webhook_sources
    assert source.mapping == %{"event_id" => "id", "status" => "state", "title" => "subject"}
    assert source.adapter_kind == :mapped_json
  end

  test "checking a payload maps it and records absolutely nothing" do
    installation!()
    {:ok, view, _html} = open()

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{
        "adapter_kind" => "mapped_json",
        "mapping" => %{
          "event_id" => "id",
          "status" => "state",
          "title" => "subject",
          "severity" => "details.severity"
        }
      })
    )
    |> render_submit()

    view
    |> form("#webhook-preview-form", %{
      "source_name" => "alerts",
      "sample" => Presets.sample(:mapped_json)
    })
    |> render_submit()

    assert has_element?(view, ".webhook-preview-result", "1 event would be recorded")
    assert has_element?(view, ".webhook-preview-result", "evt-4417")
    assert Repo.aggregate(Inbox.Entry, :count) == 0
  end

  test "a payload the mapping cannot read names the field instead of guessing one" do
    installation!()
    {:ok, view, _html} = open()

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{
        "adapter_kind" => "mapped_json",
        "mapping" => %{"event_id" => "missing", "status" => "state", "title" => "subject"}
      })
    )
    |> render_submit()

    view
    |> form("#webhook-preview-form", %{
      "source_name" => "alerts",
      "sample" => Presets.sample(:mapped_json)
    })
    |> render_submit()

    assert has_element?(view, "[role=alert]", "event_id")
    refute has_element?(view, ".webhook-preview-result")
    assert Repo.aggregate(Inbox.Entry, :count) == 0
  end

  test "a sample that is not JSON, or is larger than a real request, is refused inertly" do
    installation!()
    {:ok, view, _html} = open()
    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    view
    |> form("#webhook-preview-form", %{"source_name" => "alerts", "sample" => "not json"})
    |> render_submit()

    assert has_element?(view, "[role=alert]", "not valid JSON")

    view
    |> form("#webhook-preview-form", %{
      "source_name" => "alerts",
      "sample" => Jason.encode!(%{"pad" => String.duplicate("x", 41_000)})
    })
    |> render_submit()

    assert has_element?(view, "[role=alert]", "under 40 KB")
    assert Repo.aggregate(Inbox.Entry, :count) == 0
  end

  test "a source that changed under the editor shows what is saved now, mapping and all" do
    installation!()
    {:ok, view, _html} = open()
    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    assert {:ok, _} =
             Settings.put_webhook_source(
               %{name: "alerts", destination_conversation_ref: "slack:T0123456789:C9999999999"},
               Settings.fetch!().installation.revision,
               @actor
             )

    view
    |> form("#settings-webhooks-form", %{"destination_thread_ref" => "1788000000.000100"})
    |> render_submit()

    assert has_element?(view, "[role=alert]", "changed since you started editing")
    assert has_element?(view, ".settings-conflict dd", "C9999999999")
    assert has_element?(view, ".settings-conflict dd", "preset shape")

    assert has_element?(
             view,
             "#settings-webhooks-destination_thread_ref[value='1788000000.000100']"
           )
  end

  test "a deployment that registered no webhook credentials says so instead of offering none" do
    System.delete_env("RESPONDER_WEBHOOK_SECRET_NAMES")
    installation!()

    {:ok, view, _html} = open()

    assert has_element?(view, ".settings-notice", "registered no webhook credentials")
    refute has_element?(view, "#settings-webhooks-secret_name option[value='#{@registered}']")
  end

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/configuration")

  defp source_params(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "alerts",
        "enabled" => "true",
        "adapter_kind" => "universal",
        "auth_kind" => "hmac_sha256",
        "secret_name" => @registered,
        "destination_transport" => "slack",
        "destination_conversation_ref" => "slack:T0123456789:C0123456789",
        "context_ref" => "emisar",
        "group_by_labels" => ""
      },
      overrides
    )
  end

  defp installation! do
    {:ok, %{installation: %{revision: revision}}} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(%{ref: "emisar", base_branch: "main"}, revision, @actor)

    snapshot
  end
end
