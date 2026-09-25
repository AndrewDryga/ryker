defmodule Ryker.ControlPlane.InstructionsLiveTest do
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]
  alias Ryker.ControlPlane.{Actions, Endpoint, InstructionSettings, Projection, SlackNames}
  alias Ryker.ControlPlane.Updates
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Instructions
  alias Ryker.Slack.{ChannelConfigurationChangeset, ChannelMembership}

  @endpoint Endpoint
  @scope {:channel, "TINSTRUCTIONS", "CTEST"}

  setup do
    failures = start_supervised!({Agent, fn -> false end})
    projection_failure = start_supervised!({Agent, fn -> false end}, id: :projection_failure)

    projection =
      Map.update!(Projection.callbacks(), :channel, fn read ->
        fn workspace, channel, params ->
          if Agent.get(projection_failure, & &1),
            do: {:error, :database_unavailable},
            else: read.(workspace, channel, params)
        end
      end)

    actions =
      Map.update!(Actions.callbacks(), :save_instructions, fn save ->
        fn scope, text, revision ->
          if Agent.get(failures, & &1),
            do: raise(DBConnection.ConnectionError, message: "forced test outage")

          save.(scope, text, revision)
        end
      end)

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.ControlPlane.PubSub,
       live_view: [signing_salt: "instructions-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: actions,
         projection: projection,
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    %{failures: failures, projection_failure: projection_failure}
  end

  test "global edits save explicitly and retain drafts through refresh, validation and conflict" do
    {:ok, view, html} = open("/instructions")
    assert html =~ "For every conversation"
    assert has_element?(view, "#instructions-form button[type=submit][disabled]")
    edit(view, "First draft 🌱")
    assert Instructions.get(:global).revision == 0
    render_click(view, "refresh")
    assert has_element?(view, "#instructions-text", "First draft 🌱")
    submit(view, "First draft 🌱")
    assert Instructions.get(:global).saved_by == "control-plane:local"
    assert has_element?(view, "[role=status]", "Instructions saved")
    render_click(view, "refresh")
    assert has_element?(view, "[role=status]", "Instructions saved")

    too_long = String.duplicate("x", 2_001)
    submit(view, too_long)
    assert has_element?(view, "[role=alert]", "2,000 characters")
    assert has_element?(view, "#instructions-text", too_long)
    edit(view, "My unsaved draft")

    assert {:ok, _} =
             Instructions.save(:global, "Another operator's saved text", 1, "operator:other")

    render_click(view, "refresh")
    submit(view, "My unsaved draft")
    assert has_element?(view, "[role=alert]", "changed since you started editing")
    assert has_element?(view, "#instructions-current", "Another operator's saved text")
    assert has_element?(view, "#instructions-text", "My unsaved draft")
    assert Instructions.get(:global).revision == 2
    view |> element("button[phx-click=cancel]") |> render_click()
    assert has_element?(view, "#instructions-text", "Another operator's saved text")
    submit(view, "")
    assert Instructions.get(:global).revision == 3
    assert Instructions.get(:global).text == ""
  end

  test "Instructions reads the editor for every conversation, then channels, then what people saved" do
    # Andrew approved one Instructions place on 2026-09-24: the global editor,
    # the channels that add their own, and the preferences and guidance that
    # used to be two more pages. One sentence of description replaces the
    # "How instructions work" disclosure.
    {:ok, _view, html} = open("/instructions")
    page = LazyHTML.from_document(html) |> LazyHTML.query(".instructions-page")

    assert LazyHTML.query(page, "h1") |> LazyHTML.text() == "Instructions"

    assert LazyHTML.query(page, ".page-description") |> LazyHTML.text() ==
             "How Ryker should work. It follows these in every reply, investigation and task."

    assert Enum.empty?(LazyHTML.query(page, "details.page-help"))

    assert page
           |> LazyHTML.query("header.section-head h2")
           |> Enum.map(&LazyHTML.text/1) == [
             "For every conversation",
             "For specific channels",
             "Saved from conversations"
           ]

    editor = LazyHTML.query(page, "section.instructions-editor#instructions-global")

    assert LazyHTML.query(editor, "label[for=instructions-text]") |> LazyHTML.text() =~
             "Instructions for every conversation"

    assert LazyHTML.query(editor, "#instructions-count") |> LazyHTML.text() ==
             "2,000 characters left"

    assert LazyHTML.query(page, "#saved + .kit-toolbar nav.segmented a[aria-current]")
           |> Enum.map(&LazyHTML.text/1) == ["All", "Current"]
  end

  test "channels with their own instructions are listed under the global editor and open their editor" do
    # Channel instructions are written on a channel's page. The Instructions
    # page is where a person sees all of them at once; each row is the
    # channel, its words, and the way to its editor. A cleared channel adds
    # nothing and is not listed.
    assert {:ok, _} =
             Instructions.save(@scope, "Include the affected service.", 0, "operator:test")

    cleared = {:channel, "TINSTRUCTIONS", "CCLEARED"}
    assert {:ok, _} = Instructions.save(cleared, "Old text", 0, "operator:test")
    assert {:ok, _} = Instructions.save(cleared, "", 1, "operator:test")

    {:ok, view, _html} = open("/instructions")
    row = "section.instructions-channels article[id='channel-instructions-TINSTRUCTIONS-CTEST']"
    assert has_element?(view, row <> " h3", "Slack channel CTEST")
    assert has_element?(view, row <> " .entity-text", "“Include the affected service.”")

    assert has_element?(
             view,
             row <>
               " a[href='/channels/TINSTRUCTIONS/CTEST#instructions-slack:TINSTRUCTIONS:CTEST']",
             "Edit"
           )

    refute has_element?(view, "section.instructions-channels", "CCLEARED")
    refute has_element?(view, "section.instructions-channels", "Old text")
  end

  test "preferences and guidance saved from conversations are listed under Instructions with their controls" do
    # /preferences and /guidance were removed on 2026-09-24. Their entries
    # must stay listed, filterable and pausable here, or confirmed guidance
    # would keep shaping replies with nowhere to see or stop it.
    source = SavedEntities.source!("slack:T123:C456")

    preference =
      SavedEntities.behavior!(
        source,
        :preference,
        %{
          "expires_in" => "30d",
          "key" => "response_detail",
          "repository" => nil,
          "scope" => "conversation",
          "value" => "concise"
        },
        scope_ref: "slack:T123:C456",
        expires_at: nil
      )

    guidance =
      SavedEntities.behavior!(
        source,
        :guidance,
        %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "workspace",
          "subject" => "Migrations need a rollback note",
          "summary" => "Rollback notes",
          "text" => "Any change under db/migrations needs a rollback note.",
          "visibility" => "workspace"
        },
        scope_kind: :workspace,
        scope_ref: "slack:T123",
        expires_at: nil
      )

    {:ok, view, _html} = open("/instructions")
    preference_row = "section.instructions-saved article[id='behavior-#{preference.ref}']"
    guidance_row = "section.instructions-saved article[id='behavior-#{guidance.ref}']"
    assert has_element?(view, preference_row <> " h3", "Reply length: Concise")
    assert has_element?(view, preference_row <> " .entity-meta", "Preference")
    assert has_element?(view, guidance_row <> " h3", "Migrations need a rollback note")
    assert has_element?(view, guidance_row <> " .entity-meta", "everywhere")

    pause = "/actions/behavior/#{URI.encode_www_form(preference.ref)}/disabled"

    assert has_element?(
             view,
             preference_row <> " form.action-control[action='#{pause}']",
             "Pause"
           )

    {:ok, view, _html} = open("/instructions?show=preferences")
    assert has_element?(view, preference_row)
    refute has_element?(view, guidance_row)

    {:ok, view, _html} = open("/instructions?show=guidance")
    refute has_element?(view, preference_row)
    assert has_element?(view, guidance_row)

    {:ok, view, _html} = open("/instructions?status=past")
    refute has_element?(view, "section.instructions-saved article")

    assert has_element?(
             view,
             "section.instructions-saved .entity-empty-title",
             "No past preferences or guidance"
           )
  end

  test "the Preferences and Guidance pages are removed rather than redirected" do
    for path <- ["/preferences", "/guidance"] do
      response = get(build_conn() |> Map.put(:host, "localhost"), path)
      assert response.status == 404, path
      assert get_resp_header(response, "location") == [], path
    end
  end

  test "a change to a saved preference or guidance refreshes an open Instructions page" do
    # They moved from their own pages to /instructions; an invalidation still
    # aimed at the removed pages would leave the list stale until reconcile.
    assert Updates.domain("/instructions") == "instructions"
    state = %{connection: self(), reference: make_ref(), pending: MapSet.new(), timer: nil}

    {:noreply, pending} =
      Updates.handle_info(
        {:notification, self(), state.reference, "ryker_control_plane", "operator_behaviors"},
        state
      )

    assert MapSet.member?(pending.pending, "instructions")
    refute MapSet.member?(pending.pending, "preferences")
    refute MapSet.member?(pending.pending, "guidance")
    Process.cancel_timer(pending.timer)
  end

  test "channel page has its own editor and inherited preview without leaking text into the roster" do
    join!()
    start_supervised!({SlackNames, workspace: "TINSTRUCTIONS", fetch: fn _ -> {:ok, "test"} end})
    SlackNames.name("TINSTRUCTIONS", "CTEST")
    GenServer.call(SlackNames, :refresh)

    assert {:ok, _} =
             Instructions.save(:global, "Global <script>plain text</script>", 0, "operator:test")

    {:ok, view, html} = open("/channels/TINSTRUCTIONS/CTEST")
    assert has_element?(view, ".instructions-page h1", "#test")
    assert html =~ "Instructions for this channel"
    refute html =~ "more specific for conflicting behavioral guidance in this channel"
    refute html =~ "They cannot change permissions or fixed system rules."
    refute html =~ "take priority"
    assert has_element?(view, "#inherited-instructions", "Global <script>plain text</script>")
    refute html =~ "<script>plain text</script>"

    assert has_element?(
             view,
             "a[href='/instructions']",
             "Edit the instructions for every conversation"
           )

    submit(view, "CHANNEL_PRIVATE_INSTRUCTION")
    assert Instructions.get(@scope).text == "CHANNEL_PRIVATE_INSTRUCTION"
    assert Instructions.get(:global).revision == 1
    {:ok, _, roster} = open("/channels")
    assert roster =~ "own instructions"
    refute roster =~ "CHANNEL_PRIVATE_INSTRUCTION"
    {:ok, _, other} = open("/channels/TOTHER/CTEST")
    refute other =~ "instructions-form"
    refute other =~ "CHANNEL_PRIVATE_INSTRUCTION"
  end

  test "the channel page reads how Ryker takes part, its instructions, then what applies and what it knows" do
    # Deployed 2026-09-13 as 0.1.0-g865731d1, the editor card sat between the
    # title and everything the page leads with. On 2026-09-24 the page became
    # Kit sections in the order a person asks about a channel: how Ryker takes
    # part, what it was told here, what else applies, what it knows, then its
    # schedules, recent work and usage.
    join!()
    start_supervised!({SlackNames, workspace: "TINSTRUCTIONS", fetch: fn _ -> {:ok, "test"} end})
    SlackNames.name("TINSTRUCTIONS", "CTEST")
    GenServer.call(SlackNames, :refresh)

    {:ok, _view, html} = open("/channels/TINSTRUCTIONS/CTEST")
    page = LazyHTML.from_document(html) |> LazyHTML.query(".instructions-page")

    outline =
      page
      |> LazyHTML.query(
        "header.page-header, p.channel-state, section.channel-section, header.section-head#channel-instructions, section.instructions-editor"
      )
      |> Enum.map(fn node ->
        [tag] = LazyHTML.tag(node)
        [class | _] = LazyHTML.attribute(node, "class") |> hd() |> String.split()
        id = LazyHTML.attribute(node, "id") |> List.first()
        "#{tag}.#{class}" <> if(id, do: "##{id}", else: "")
      end)

    assert outline == [
             "header.page-header",
             "p.channel-state",
             "section.channel-section#taking-part",
             "header.section-head#channel-instructions",
             "section.instructions-editor#instructions-slack:TINSTRUCTIONS:CTEST",
             "section.channel-section#applies",
             "section.channel-section#knows",
             "section.channel-section#schedules",
             "section.channel-section#episodes",
             "section.channel-section#usage"
           ]

    assert page |> LazyHTML.query("header.page-header h1") |> LazyHTML.text() == "#test"
    assert page |> LazyHTML.query("p.channel-state") |> LazyHTML.text() =~ "Ryker is in"
    refute html =~ "How context reaches this channel"
  end

  test "a channel revoked while editing cannot save and the existing draft stays visible" do
    membership = join!()
    {:ok, view, _} = open("/channels/TINSTRUCTIONS/CTEST")
    edit(view, "Unsaved private text")

    membership
    |> Ecto.Changeset.change(status: :left, left_at: DateTime.utc_now())
    |> Repo.update!()

    submit(view, "Unsaved private text")
    assert Instructions.get(@scope).revision == 0
    assert has_element?(view, "[role=alert]", "no longer available")
    assert has_element?(view, "#instructions-text", "Unsaved private text")
  end

  test "operator callbacks reject unknown or malformed scopes without creating settings" do
    actions = Actions.callbacks()

    for scope <- [{:channel, "TUNKNOWN", "CUNKNOWN"}, {:channel, "../T", "C"}, :personal] do
      assert {:error, :instructions_scope_unavailable} =
               actions.save_instructions.(scope, "text", 0)
    end

    assert Repo.aggregate(Ryker.Instructions.Setting, :count) == 0
  end

  test "departed channel instructions remain visible and clearable without allowing replacement" do
    # Leaving a channel must not make its customer-authored instructions impossible to remove.
    membership = join!()
    assert {:ok, _} = Instructions.save(@scope, "Retired channel guidance", 0, "operator:test")

    membership
    |> Ecto.Changeset.change(status: :left, left_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, view, _} = open("/channels/TINSTRUCTIONS/CTEST")
    assert has_element?(view, "#instructions-text", "Retired channel guidance")
    submit(view, "Replacement is not allowed")
    assert has_element?(view, "[role=alert]", "no longer available")
    assert Instructions.get(@scope).text == "Retired channel guidance"
    submit(view, " \r\n ")
    assert Instructions.get(@scope).text == ""
    assert Instructions.get(@scope).revision == 2
    assert Repo.aggregate(Ryker.Instructions.Edit, :count) == 2
  end

  test "configured and historically known channels need no membership row to retain instruction access" do
    configuration = %{
      actor_ref: "operator:test",
      alert_policy: :offer,
      channel_ref: "CCONFIGURED",
      id: Ecto.UUID.generate(),
      participation: :mentions,
      revision: 1,
      saved_at: DateTime.utc_now(),
      workspace_ref: "TINSTRUCTIONS"
    }

    configuration
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()

    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ryker.Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "instruction-history:#{id}",
                 native_input_id: "history:#{id}",
                 turn_ref: "turn:#{id}",
                 destination: %{
                   transport: "slack",
                   conversation_ref: "slack:TINSTRUCTIONS:CHISTORY",
                   thread_ref: nil
                 }
               })
             )

    for channel <- ["CCONFIGURED", "CHISTORY"] do
      scope = {:channel, "TINSTRUCTIONS", channel}
      assert {:ok, _} = InstructionSettings.save(scope, "Known channel", 0)

      assert {:ok, %{setting: %{text: "Known channel"}}} =
               InstructionSettings.fetch(scope)
    end

    assert Repo.aggregate(ChannelMembership, :count) == 0
  end

  test "a channel projection outage preserves the editor and uses the existing unavailable state",
       %{
         projection_failure: failure
       } do
    join!()
    {:ok, view, _} = open("/channels/TINSTRUCTIONS/CTEST")
    edit(view, "Draft during an outage")
    Agent.update(failure, fn _ -> true end)
    render_click(view, "refresh")
    assert has_element?(view, ".app-warning", "This view could not refresh")
    assert has_element?(view, "#instructions-text", "Draft during an outage")
    Agent.update(failure, fn _ -> false end)
    render_click(view, "refresh")
    refute has_element?(view, ".app-warning", "This view could not refresh")
    assert has_element?(view, "#instructions-text", "Draft during an outage")
  end

  test "over-limit text says how much to remove instead of a negative remaining count" do
    {:ok, view, _} = open("/instructions")
    edit(view, String.duplicate("x", 2_001))
    assert has_element?(view, "#instructions-count", "1 character over the limit")
    edit(view, String.duplicate("x", 2_002))
    assert has_element?(view, "#instructions-count", "2 characters over the limit")
  end

  test "typing after a conflict keeps the explanation until the saved version is reviewed" do
    # Losing the explanation left Save disabled without telling the operator why.
    {:ok, view, _} = open("/instructions")
    edit(view, "My draft")
    assert {:ok, _} = Instructions.save(:global, "Concurrent edit", 0, "operator:other")
    submit(view, "My draft")
    edit(view, "My revised draft")
    assert has_element?(view, "[role=alert]", "changed since you started editing")
    assert has_element?(view, "#instructions-form button[type=submit][disabled]")
    assert has_element?(view, "input[name=revision][value='0']")
    view |> element("button[phx-click=review-current]") |> render_click()
    refute has_element?(view, "[role=alert]")
    assert has_element?(view, "#instructions-text", "My revised draft")
    submit(view, "My revised draft")
    assert Instructions.get(:global).text == "My revised draft"
    assert Instructions.get(:global).revision == 2
  end

  test "the quiet instruction counter measures normalized saved bytes" do
    # The counter used to announce each keystroke and count bytes that save removed.
    {:ok, view, _} = open("/instructions")
    pasted = String.duplicate("👩‍💻\r\n", 643)
    edit(view, pasted)
    assert has_element?(view, "#instructions-count", "714 characters left · 7,716 of 8,192 bytes")
    refute has_element?(view, "#instructions-count[role=status]")
    submit(view, pasted)
    assert Instructions.get(:global).text == String.replace(pasted, "\r\n", "\n")
  end

  test "a recovered browser draft keeps its old revision and cannot overwrite a save during disconnect" do
    assert {:ok, _} = Instructions.save(:global, "First", 0, "operator:test")
    assert {:ok, _} = Instructions.save(:global, "Saved during disconnect", 1, "operator:other")
    {:ok, view, _} = open("/instructions")

    view
    |> element("#instructions-form")
    |> render_change(%{"text" => "Recovered draft", "revision" => "1"})

    submit(view, "Recovered draft")
    assert has_element?(view, "[role=alert]", "changed since you started editing")
    assert Instructions.get(:global).text == "Saved during disconnect"
  end

  test "an unconfirmed save keeps the submitted revision as well as the draft", %{
    failures: failures
  } do
    assert {:ok, _} = Instructions.save(:global, "First", 0, "operator:test")
    assert {:ok, _} = Instructions.save(:global, "Concurrent save", 1, "operator:other")
    {:ok, view, _} = open("/instructions")
    Agent.update(failures, fn _ -> true end)

    view
    |> element("#instructions-form")
    |> render_submit(%{"text" => "Recovered draft", "revision" => "1"})

    assert has_element?(view, "[role=alert]", "could not be confirmed")
    assert has_element?(view, "#instructions-text", "Recovered draft")
    assert has_element?(view, "input[name=revision][value='1']")
    Agent.update(failures, fn _ -> false end)
    submit(view, "Recovered draft")
    assert Instructions.get(:global).text == "Concurrent save"
    assert has_element?(view, "#instructions-current", "Concurrent save")
    view |> element("button[phx-click=review-current]") |> render_click()
    submit(view, "Recovered draft")
    assert Instructions.get(:global).text == "Recovered draft"
    assert Instructions.get(:global).revision == 3
  end

  defp open(path), do: live(build_conn() |> Map.put(:host, "localhost"), path)

  defp edit(view, text),
    do: view |> element("#instructions-form") |> render_change(%{"text" => text})

  defp submit(view, text),
    do: view |> element("#instructions-form") |> render_submit(%{"text" => text})

  defp join! do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "TINSTRUCTIONS",
      channel_ref: "CTEST",
      status: :joined,
      generation: 1,
      private: true,
      external_shared: false,
      joined_at: DateTime.utc_now()
    })
  end
end
