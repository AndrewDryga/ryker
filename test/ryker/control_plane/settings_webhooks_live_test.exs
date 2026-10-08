defmodule Ryker.ControlPlane.SettingsWebhooksLiveTest do
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, Projection}
  alias Ryker.Credentials
  alias Ryker.Ingress.Inbox
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfiguration
  alias Ryker.Slack.Names
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
       pubsub_server: Ryker.PubSub.Server,
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
             Names.name("T0123456789", "C0123456789")
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

  test "a source form with no environment points straight at adding one" do
    # QA P3, 2026-09-26: Environments promised "Adding a repository creates the
    # Default environment" while a repository first needed GitHub repaired.
    # This notice made the same promise with GitHub not even connected, to a
    # sender that needs no repository: the one step that always works is
    # adding an environment.
    {:ok, _snapshot} = Settings.initialize(@actor)
    {:ok, view, _html} = open()
    open_source_editor(view)

    notice =
      view
      |> element("#settings-webhooks .settings-notice", "there is none yet")
      |> render()

    assert notice =~ "Work from a webhook runs in an environment, and there is none yet."
    refute notice =~ "repository"

    assert has_element?(
             view,
             "#settings-webhooks .settings-notice a[href='/environments/new']",
             "Add an environment"
           )

    # Before Slack runs, a source that posts there waits, and the page says so
    # with the reason every page gives for Slack's state.
    assert has_element?(
             view,
             "#settings-webhooks .settings-notice",
             "Ryker cannot read or reply in Slack until you connect it. Until then a source " <>
               "that posts to Slack doesn't take events"
           )

    assert has_element?(
             view,
             "#settings-webhooks .settings-notice a[href='/integrations/slack']",
             "Connect Slack"
           )
  end

  # Andrew, 2026-09-28: a box saying "Create a signing credential above before
  # adding a webhook source." sat over the list. The Add it blocks cannot be
  # pressed now and says why on hover.
  test "with no signing credential, Add webhook source is disabled and says why on hover" do
    installation!()
    assert Credentials.delete(:webhook, @registered, @actor) == :ok
    {:ok, view, _html} = open()

    blocked =
      "#settings-webhooks span.settings-editor-add.is-disabled[aria-disabled='true']" <>
        "[title='Create a signing credential above before adding a webhook source.']"

    assert has_element?(view, blocked, "Add webhook source")
    refute has_element?(view, "#settings-webhooks a.settings-editor-add")
    refute has_element?(view, "#settings-webhooks .settings-notice", "signing credential")
  end

  test "a source may only reference a credential Ryker has in encrypted custody" do
    installation!()
    {:ok, view, _html} = open()

    assert has_element?(
             view,
             "#settings-webhooks a.settings-editor-add[href='/integrations/webhooks/sources/new']",
             "Add webhook source"
           )

    assert has_element?(
             view,
             "section[aria-label='Signing credentials'] .section-head a[href='/integrations/webhooks/credentials/new']",
             "Add signing credential"
           )

    open_source_editor(view)

    assert has_element?(view, "#settings-webhooks-secret_name option[value='#{@registered}']")
    refute has_element?(view, "#settings-webhooks-secret_name option[value='SLACK_BOT_TOKEN']")

    revision = Settings.fetch!().installation.revision

    assert Actions.callbacks().put_settings_item.(
             :webhooks,
             Map.put(source_params(), "secret_name", "SLACK_BOT_TOKEN"),
             revision,
             nil
           ) == {:error, {:invalid_settings, [{:secret_name, :unregistered_secret}]}}

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

  # A new source is named by what was typed, so the message looked for its row
  # before asking whether it was new: adding "alerts" said "alerts was saved.",
  # the words for an edit. A new one is added; an edited one is saved.
  test "a new webhook source is said to be added, and an edited one saved" do
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
    view |> form("#settings-webhooks-form", source_params()) |> render_submit()

    assert_patch(view, "/integrations/webhooks")
    assert has_element?(view, ".form-feedback-success", "alerts was added.")

    view = edit_source(view)

    view
    |> form("#settings-webhooks-form", %{"group_by_labels" => "service"})
    |> render_submit()

    assert_patch(view, "/integrations/webhooks")
    assert has_element?(view, ".form-feedback-success", "alerts was saved.")
  end

  test "a source that changed under the editor shows what is saved now, mapping and all" do
    installation!()
    {:ok, view, _html} = open()
    open_source_editor(view)
    view |> form("#settings-webhooks-form", source_params()) |> render_submit()
    assert_patch(view, "/integrations/webhooks")

    view = edit_source(view)

    # Someone saves the source while this person is typing into its form.
    view
    |> form("#settings-webhooks-form", %{"destination_thread_ref" => "1788000000.000100"})
    |> render_change()

    assert {:ok, _} =
             Settings.put_webhook_source(
               %{name: "alerts", destination_conversation_ref: "slack:T0123456789:C9999999999"},
               Settings.fetch!().installation.revision,
               @actor
             )

    view |> form("#settings-webhooks-form") |> render_submit()

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
    assert has_element?(view, "#settings-webhooks .entity-row .state-word[data-tone=on]", "On")

    # The address is on the source's own page, above its form, with a copy
    # button; the list's row only opens that page.
    refute has_element?(view, "#settings-webhooks .entity-row button")
    view = edit_source(view)

    assert has_element?(
             view,
             "#settings-webhooks .settings-address code",
             "http://127.0.0.1:4320/v1/hooks/alerts"
           )

    assert has_element?(
             view,
             "#settings-webhooks .settings-address button[data-copy-value='http://127.0.0.1:4320/v1/hooks/alerts']"
           )
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

    assert has_element?(view, "#confirm-delete-webhook-credential", "Delete #{@registered}?")

    assert has_element?(
             view,
             "#confirm-delete-webhook-credential",
             "can no longer deliver events"
           )

    assert {:ok, _secret} = Credentials.fetch(:webhook, @registered)

    view
    |> element("#confirm-delete-webhook-credential button", "Delete credential")
    |> render_click()

    assert Credentials.fetch(:webhook, @registered) == {:error, :credential_missing}
    assert has_element?(view, ".form-feedback-success", "#{@registered} was deleted.")
  end

  # Andrew, 2026-09-27: an add form opened above its list "blends into the
  # content"; every form that adds to a list has a page of its own. A new
  # signing credential's secret is shown once, on the list it was added to.
  test "a signing credential and a webhook source are each added on a page of their own" do
    installation!()
    {:ok, view, _html} = open()
    refute has_element?(view, "form[phx-submit=create-webhook-credential]")

    view
    |> element(
      "section[aria-label='Signing credentials'] .section-head a",
      "Add signing credential"
    )
    |> render_click()

    assert_patch(view, "/integrations/webhooks/credentials/new")
    assert has_element?(view, "main h1", "Add a signing credential")
    assert has_element?(view, "nav.kit-back a[href='/integrations/webhooks']", "Webhooks")
    assert has_element?(view, ".kit-form-card form[phx-submit=create-webhook-credential]")
    refute has_element?(view, ".entity-list")

    view
    |> form("form[phx-submit=create-webhook-credential]", %{
      "credential" => %{"name" => "grafana", "secret" => ""}
    })
    |> render_submit()

    assert_patch(view, "/integrations/webhooks")
    assert has_element?(view, ".form-feedback-success", "Signing credential grafana is ready.")
    assert has_element?(view, ".secret-reveal", "Signing secret")
    assert has_element?(view, "#webhook-credential-grafana")

    # Sources follow the same rule, through the settings editor.
    open_source_editor(view)
    assert_patch(view, "/integrations/webhooks/sources/new")
    assert has_element?(view, "main h1", "Add a webhook source")
    assert has_element?(view, ".kit-form-card #settings-webhooks-form")
    refute has_element?(view, "section[aria-label='Signing credentials']")
  end

  # A new signing secret is shown once, on the list it was added to. It stayed on every settings
  # page the person moved to after that, because nothing cleared it (2026-10-04 review).
  test "a new signing secret is shown once and gone from the next page" do
    installation!()

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/integrations/webhooks/credentials/new")

    view
    |> form("form[phx-submit=create-webhook-credential]", %{
      "credential" => %{"name" => "grafana", "secret" => ""}
    })
    |> render_submit()

    assert_patch(view, "/integrations/webhooks")
    assert has_element?(view, ".secret-reveal", "Signing secret")

    render_patch(view, "/integrations/webhooks/sources/new")
    refute has_element?(view, ".secret-reveal")

    render_patch(view, "/integrations/webhooks")
    refute has_element?(view, ".secret-reveal")
  end

  test "a refused signing credential is said in the error tone, not as a success" do
    # Every refusal on the connection pages rendered with the success tone.
    installation!()

    {:ok, view, _html} =
      live(build_conn() |> Map.put(:host, "localhost"), "/integrations/webhooks/credentials/new")

    view
    |> form("form[phx-submit=create-webhook-credential]", %{
      "credential" => %{"name" => "Bad Name", "secret" => ""}
    })
    |> render_submit()

    # The form stays, with what to fix.
    assert has_element?(view, ".form-feedback-error[role=alert]", "That name cannot be used.")
    assert has_element?(view, "form[phx-submit=create-webhook-credential]")
    refute has_element?(view, ".form-feedback-success")
  end

  test "the page says what Slack is waiting for in the words every other page uses" do
    # QA re-test, 2026-09-26: with Slack's tokens verified and nobody chosen
    # to manage Ryker, Webhooks said "Slack is not connected, so Ryker cannot
    # post these events yet" and its channel list "Ryker is not in any Slack
    # channel yet", while every other page said "Finish connecting".
    snapshot = installation_without_channels!()

    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          enabled: false,
          workspace_ref: "T0123456789",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker"
        },
        snapshot.installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end

    {:ok, view, _html} = open()

    assert has_element?(
             view,
             ".settings-notice",
             "The tokens are verified, but Slack stays off until you choose who can manage Ryker."
           )

    assert has_element?(view, ".settings-notice a[href='/integrations/slack']", "Choose people")
    refute render(view) =~ "Slack is not connected"

    open_source_editor(view)

    assert has_element?(
             view,
             "#settings-webhooks-form",
             "Ryker lists the channels it is in once Slack is on."
           )

    refute render(view) =~ "not in any Slack channel yet"
  end

  defp open, do: live(conn(), "/integrations/webhooks")

  defp conn, do: build_conn() |> Map.put(:host, "localhost")

  # A source's row opens its own page from anywhere on the row.
  defp edit_source(view) do
    {:ok, view, _html} =
      view
      |> element("#settings-webhooks .entity-name a", "alerts")
      |> render_click()
      |> follow_redirect(conn(), "/integrations/webhooks/sources/alerts/edit")

    view
  end

  defp open_source_editor(view) do
    view |> element("#settings-webhooks a.settings-editor-add") |> render_click()
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
    |> ChannelConfiguration.Changeset.membership()
    |> Repo.insert!()
  end

  # An installation with an environment, and a Slack channel Ryker is in for
  # sources to post to.
  defp installation! do
    joined_channel!("C0123456789")
    installation_without_channels!()
  end

  defp installation_without_channels! do
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
