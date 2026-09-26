defmodule Ryker.ControlPlane.SettingsWebhooksLiveTest do
  use Ryker.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Actions, Endpoint, Projection, SlackNames}
  alias Ryker.Credentials
  alias Ryker.Ingress.Inbox
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfigurationChangeset
  alias Ryker.Webhooks.Presets

  @endpoint Endpoint
  @actor "control-plane:local"
  @registered "alertmanager"

  setup do
    {:ok, _} = Credentials.put(:webhook, @registered, "test-secret-long-enough", @actor)
    {:ok, _} = Credentials.verify(:webhook, @registered, :verified, @actor)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
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

  test "the source form offers what Ryker has and explains each choice in plain words" do
    # QA, 2026-09-25: the Environment select offered only "Not set" and said
    # nothing until a submit, the channel was a text box showing
    # slack:T0123456789:C0123456789, the choices were named by their internal
    # kinds, and "Deployment filters" listed four bare field names.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)

    form = "#settings-webhooks-form"

    # A new source starts on what this installation has: its default
    # environment and its only signing credential, accepting events.
    assert has_element?(
             view,
             "#{form} select[name=environment_ref] option[selected]",
             "Production"
           )

    assert has_element?(view, "#{form} select[name=secret_name] option[selected]", @registered)
    assert has_element?(view, "#{form} input[type=checkbox][name=enabled][checked]")

    for select <- ~w(environment_ref secret_name destination_transport) do
      refute has_element?(view, "#{form} select[name=#{select}] option", "Not set"), select
    end

    # The channel is chosen from the channels Ryker is in, by the name the
    # rest of Ryker shows for it.
    assert has_element?(
             view,
             "#{form} select[name=destination_conversation_ref] option[value='slack:T0123456789:C0123456789']",
             SlackNames.name("T0123456789", "C0123456789")
           )

    refute has_element?(view, "#{form} [placeholder*='T0123456789']")

    # Each way to prove a sender says what it means, and signing says how
    # long its secret must be.
    assert has_element?(
             view,
             "#{form} fieldset#settings-webhooks-auth_kind",
             "at least 32 characters"
           )

    assert has_element?(view, "#{form} fieldset#settings-webhooks-adapter_kind", "Grafana")
    refute render(view) =~ "HMAC SHA-256)"
    refute render(view) =~ "Deployment filters"
    assert has_element?(view, "#{form} details summary", "Deployment reports")
  end

  test "a source missing what it needs says each thing to choose, all at once" do
    # QA, 2026-09-25: an unset credential answered "Signing credential is not a
    # signing credential Ryker has.", and nothing else until that was fixed.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)

    view
    |> form("#settings-webhooks-form", %{"name" => "alerts"})
    |> render_submit(%{"secret_name" => "", "environment_ref" => ""})

    assert has_element?(
             view,
             "#settings-webhooks .settings-error",
             "Choose the signing credential this sender uses. Add one under Signing credentials above if there is none."
           )

    assert has_element?(
             view,
             "#settings-webhooks .settings-error",
             "Choose the environment the work from these events runs in."
           )

    assert Settings.fetch!().webhook_sources == []
  end

  test "a source form with no environment to choose says how to make one" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    {:ok, view, _html} = open()
    open_source_editor(view)

    assert has_element?(
             view,
             "#settings-webhooks .settings-notice",
             "Work from a webhook runs in an environment, and there is none yet."
           )

    assert has_element?(view, "#settings-webhooks .settings-notice a[href='/environments']")
  end

  test "a source may only reference a credential Ryker has in encrypted custody" do
    installation!()
    {:ok, view, _html} = open()

    assert has_element?(
             view,
             "#settings-webhooks button.settings-editor-add",
             "Add webhook source"
           )

    assert has_element?(
             view,
             "button[phx-click=show-webhook-credential-form]",
             "Add signing credential"
           )

    open_source_editor(view)

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

  test "a webhook source chooses the environment its work runs in" do
    # A source named a repository context by ref until 2026-09-25. Work from
    # a source runs in an environment now, chosen by the name people know it
    # by, and the source's row says where its work runs.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)

    assert has_element?(
             view,
             "select#settings-webhooks-environment_ref option[value=production]",
             "Production"
           )

    refute has_element?(view, "#settings-webhooks-form [name=context_ref]")

    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    assert [%{name: "alerts", environment_ref: "production"}] = Settings.fetch!().webhook_sources
    assert has_element?(view, "#settings-webhooks .entity-meta", "Runs in Production")
  end

  test "a custom mapping is saved as bounded paths and its required fields are named" do
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
    choose_custom_json(view)

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{
        "adapter_kind" => "mapped_json",
        "mapping" => %{"status" => "state", "title" => "subject"}
      })
    )
    |> render_submit()

    assert has_element?(
             view,
             ".settings-error",
             "Fill in where the event ID, status and title are."
           )

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
    open_source_editor(view)
    choose_custom_json(view)

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

  test "a payload the mapping cannot read names the field in words and where to look" do
    # The check answered "The payload has no usable event_id. Check the
    # mapping path for that field.": the field's internal name, and advice
    # about a mapping that a Grafana source does not even have.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
    choose_custom_json(view)

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

    assert has_element?(
             view,
             "[role=alert]",
             "This payload has no usable Event ID. Check where the mapping says the Event ID is."
           )

    refute has_element?(view, "[role=alert]", "event_id")
    refute has_element?(view, ".webhook-preview-result")
    assert Repo.aggregate(Inbox.Entry, :count) == 0

    # A Grafana source has no mapping to check: it says what a Grafana
    # delivery needs instead.
    open_source_editor(view)

    view
    |> form(
      "#settings-webhooks-form",
      source_params(%{"name" => "grafana", "adapter_kind" => "grafana"})
    )
    |> render_submit()

    view
    |> form("#webhook-preview-form", %{
      "source_name" => "grafana",
      "sample" => ~s({"status": "firing"})
    })
    |> render_submit()

    assert has_element?(
             view,
             "[role=alert]",
             "This is not a Grafana alert delivery Ryker can read: it has no usable alerts."
           )
  end

  test "a sample that is not JSON, or is larger than a real request, is refused inertly" do
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
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
    open_source_editor(view)
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

  test "every webhook source shows the address its sender posts to" do
    # The receiving address was never shown, so a sender could only be pointed
    # at Ryker by someone who already knew the route shape.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)

    assert has_element?(
             view,
             "#settings-webhooks .settings-help",
             "Senders post to http://127.0.0.1:4320/v1/hooks/<source name>."
           )

    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    assert has_element?(
             view,
             "#settings-webhooks .settings-address code",
             "http://127.0.0.1:4320/v1/hooks/alerts"
           )

    assert has_element?(
             view,
             "#settings-webhooks .settings-address button[data-copy-value='http://127.0.0.1:4320/v1/hooks/alerts']"
           )

    assert has_element?(view, "#settings-webhooks .entity-row .state-word[data-tone=on]", "On")
  end

  test "a signing credential a source uses is not deleted, and the refusal names the source" do
    # Deleting a credential in use answered "Connection could not be verified",
    # in the success tone, about a connection nobody had tried to verify.
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    assert has_element?(view, "[aria-label='Signing credentials'] .entity-meta", "Used by alerts")
    refute has_element?(view, "button[phx-value-action=delete-webhook-credential]")

    render_click(view, "confirm-settings-action", %{
      "action" => "delete-webhook-credential",
      "ref" => @registered
    })

    render_click(view, "delete-webhook-credential", %{"name" => @registered})

    assert has_element?(view, ".form-feedback-error", "#{@registered} is in use by alerts.")
    refute has_element?(view, ".form-feedback-success")
    assert {:ok, _secret} = Credentials.fetch(:webhook, @registered)
  end

  test "an unused signing credential is deleted only after the question is answered" do
    installation!()
    {:ok, view, _html} = open()

    view
    |> element("button[phx-value-action=delete-webhook-credential]", "Delete")
    |> render_click()

    assert has_element?(view, ".settings-confirm", "Delete #{@registered}?")
    assert has_element?(view, ".settings-confirm", "can no longer deliver events")
    assert {:ok, _secret} = Credentials.fetch(:webhook, @registered)

    view |> element(".settings-confirm button", "Delete credential") |> render_click()

    assert {:error, :credential_missing} = Credentials.fetch(:webhook, @registered)
    assert has_element?(view, ".form-feedback-success", "#{@registered} was deleted.")
  end

  test "Add opens its form above the list it adds to, and pressed again closes it" do
    # Andrew, 2026-09-25, of Model prices, and every list with an Add button
    # like it: a button at the top that opens its form under the whole list
    # reads as a button that does nothing.
    installation!()
    {:ok, view, _html} = open()

    section = "section[aria-label='Signing credentials']"
    add = "#{section} .section-head button"
    assert has_element?(view, "#{add}[aria-expanded=false]", "Add signing credential")

    view |> element(add) |> render_click()

    assert has_element?(view, "#{section} > .settings-editor ~ .entity-list")

    assert has_element?(
             view,
             "#{section} > .settings-editor form[phx-submit=create-webhook-credential]"
           )

    refute has_element?(view, "#{section} > .entity-list ~ .settings-editor")

    view |> element(add) |> render_click()
    refute has_element?(view, "form[phx-submit=create-webhook-credential]")

    # Sources follow the same rule, through the settings editor.
    open_source_editor(view)
    assert has_element?(view, "#settings-webhooks-form")
    refute has_element?(view, "#settings-webhooks > .entity-list ~ .settings-editor")
    assert has_element?(view, "#settings-webhooks button.settings-editor-add[aria-expanded=true]")
  end

  test "a refused signing credential is said in the error tone, not as a success" do
    # Every refusal on the connection pages rendered with the success tone.
    installation!()
    {:ok, view, _html} = open()
    view |> element("button[phx-click=show-webhook-credential-form]") |> render_click()

    view
    |> form("form[phx-submit=create-webhook-credential]", %{
      "credential" => %{"name" => "Bad Name", "secret" => ""}
    })
    |> render_submit()

    assert has_element?(view, ".form-feedback-error[role=alert]", "That name cannot be used.")
    refute has_element?(view, ".form-feedback-success")
  end

  test "an installation with no webhook credentials says how to create one" do
    assert {:ok, :ok} = Credentials.delete(:webhook, @registered, @actor)
    installation!()

    {:ok, view, _html} = open()

    assert has_element?(view, ".settings-notice", "Create a signing credential")
    refute has_element?(view, "#settings-webhooks-secret_name option[value='#{@registered}']")
  end

  defp open, do: live(build_conn() |> Map.put(:host, "localhost"), "/integrations/webhooks")

  defp open_source_editor(view) do
    view |> element("#settings-webhooks button.settings-editor-add") |> render_click()
  end

  defp choose_custom_json(view) do
    view
    |> form("#settings-webhooks-form", %{"adapter_kind" => "mapped_json"})
    |> render_change()

    assert has_element?(view, "#settings-webhooks-mapping-event_id")
  end

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
        "environment_ref" => "production",
        "group_by_labels" => ""
      },
      overrides
    )
  end

  # A Slack channel Ryker is in, so a source can post to it.
  defp joined_channel!(channel) do
    %{
      channel_ref: channel,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: DateTime.utc_now(),
      private: false,
      external_shared: false,
      status: :joined,
      workspace_ref: "T0123456789"
    }
    |> ChannelConfigurationChangeset.membership()
    |> Repo.insert!()
  end

  # An installation with an environment, and a Slack channel Ryker is in for
  # sources to post to.
  defp installation! do
    joined_channel!("C0123456789")
    {:ok, %{installation: %{revision: revision}}} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_repository(%{ref: "emisar", base_branch: "main"}, revision, @actor)

    {:ok, snapshot} =
      Settings.put_environment(
        %{ref: "production", display_name: "Production", repositories: ["emisar"]},
        snapshot.installation.revision,
        @actor
      )

    snapshot
  end
end
