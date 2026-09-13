defmodule Ryker.ControlPlane.InstructionsLiveTest do
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Endpoint, InstructionSettings, Projection, SlackNames}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
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
    assert html =~ "Global instructions"
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

  test "channel page has its own editor and inherited preview without leaking text into the roster" do
    join!()
    start_supervised!({SlackNames, workspace: "TINSTRUCTIONS", fetch: fn _ -> {:ok, "test"} end})
    SlackNames.name("TINSTRUCTIONS", "CTEST")
    GenServer.call(SlackNames, :refresh)

    assert {:ok, _} =
             Instructions.save(:global, "Global <script>plain text</script>", 0, "operator:test")

    {:ok, view, html} = open("/channels/TINSTRUCTIONS/CTEST")
    assert has_element?(view, ".instructions-page h1", "#test")
    assert html =~ "Channel instructions"
    assert has_element?(view, "#inherited-instructions", "Global <script>plain text</script>")
    refute html =~ "<script>plain text</script>"
    assert has_element?(view, "a[href='/instructions']", "Edit global instructions")
    submit(view, "CHANNEL_PRIVATE_INSTRUCTION")
    assert Instructions.get(@scope).text == "CHANNEL_PRIVATE_INSTRUCTION"
    assert Instructions.get(:global).revision == 1
    {:ok, _, roster} = open("/channels")
    assert roster =~ "Global + channel"
    refute roster =~ "CHANNEL_PRIVATE_INSTRUCTION"
    {:ok, _, other} = open("/channels/TOTHER/CTEST")
    refute other =~ "instructions-form"
    refute other =~ "CHANNEL_PRIVATE_INSTRUCTION"
  end

  test "the channel page reads title, episodes, help, its instructions, then its configuration" do
    # Deployed 2026-09-13 as 0.1.0-g865731d1, the editor card sat between the
    # title and everything the approved page leads with: the quiet episode
    # count and the help disclosure came after a 400px form. The editor is one
    # section in the page's own order, not a card the page is arranged around.
    join!()
    start_supervised!({SlackNames, workspace: "TINSTRUCTIONS", fetch: fn _ -> {:ok, "test"} end})
    SlackNames.name("TINSTRUCTIONS", "CTEST")
    GenServer.call(SlackNames, :refresh)

    {:ok, _view, html} = open("/channels/TINSTRUCTIONS/CTEST")
    page = LazyHTML.from_document(html) |> LazyHTML.query(".instructions-page")

    outline =
      page
      |> LazyHTML.query(
        "header.page-header, p.channel-metrics, details.page-help, section.instructions-editor, section.channel-section"
      )
      |> Enum.map(fn node ->
        [tag] = LazyHTML.tag(node)
        [class | _] = LazyHTML.attribute(node, "class") |> hd() |> String.split()
        id = LazyHTML.attribute(node, "id") |> List.first()
        "#{tag}.#{class}" <> if(id, do: "##{id}", else: "")
      end)

    assert Enum.take(outline, 5) == [
             "header.page-header",
             "p.channel-metrics",
             "details.page-help#channel-help",
             "section.instructions-editor#instructions-slack:TINSTRUCTIONS:CTEST",
             "section.channel-section#configuration"
           ]
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
      repository_ref: "ryker",
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
    assert has_element?(view, "#instructions-count", "7716 / 8,192 bytes")
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
