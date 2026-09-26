defmodule Ryker.Slack.NamesTest do
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.ControlPlane.SlackMarkdown
  use ExUnit.Case, async: false
  alias Ryker.InspectionRedactor
  alias Ryker.Slack.{MembershipReconciler, Names}
  alias Ryker.TestSupport.FakeSlackAPI

  defmodule Unchanged do
    def reconcile_joined(_workspace_ref, _channels, _catalog), do: {:ok, []}
    def reconcile_absent(_workspace_ref, _channels, _snapshot_started_at), do: {:ok, 0}
  end

  # After every restart the Channels and Setup pages read "Slack channel
  # C0BLU1GACKC and 3 other channels" until the cache had asked Slack about
  # each channel in turn, one every 1.6 s, although the membership sweep that
  # runs at start had just listed every channel with its name. Andrew,
  # 2026-09-26: people and channels read by name, never by Slack ID.
  test "the channel sweep at start names every channel Ryker is in, with no lookup for each" do
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:error, :unavailable}
       end}
    )

    slack =
      start_supervised!(
        {FakeSlackAPI,
         channels: [
           %{channel_ref: "C456", name: "infra", external_shared: false, private: false},
           %{channel_ref: "G789", external_shared: false, private: true}
         ]}
      )

    assert {:ok, %{channels: 2}} =
             MembershipReconciler.run_once(%{
               api: FakeSlackAPI,
               client: slack,
               configurations: Unchanged,
               setup_handler: nil,
               setup_options: %{catalog: nil},
               workspace_ref: "T123"
             })

    assert Names.name("T123", "C456") == "#infra"
    assert Names.name("T123", "G789") == "Slack channel G789"
    assert :ok = GenServer.call(Names, :refresh)
    refute_received {:lookup, "C456"}
  end

  # Right after a restart, a message page's title read "Hi Slack user" for
  # "Hi @Ryker" until the cache had asked Slack who Ryker's own bot user is,
  # which it already knew from its settings (2026-09-26).
  test "Ryker's own name is known from the start, before Slack is asked" do
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T123",
       known: [{"UBOT", "Ryker"}],
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:error, :unavailable}
       end}
    )

    assert Names.name("T123", "UBOT") == "@Ryker"
    assert :ok = GenServer.call(Names, :refresh)
    refute_received {:lookup, "UBOT"}
  end

  test "names are scoped to the configured workspace and unavailable names do not block rendering" do
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:ok, "test"}
       end}
    )

    assert Names.name("T123", "C456") == "Slack channel C456"
    assert Names.name("T999", "C456") == "Slack channel C456"
    assert :ok = GenServer.call(Names, :refresh)
    assert_receive {:lookup, "C456"}
    assert Names.name("T123", "C456") == "#test"
    assert Names.name("T999", "C456") == "Slack channel C456"
    assert Names.destination("slack:T123:C456") == "#test"
    refute_receive {:lookup, "C456"}
  end

  test "a resolved user mention carries one sigil, from the directory, not two" do
    # The first Slack episode after the rename rendered its opening message as
    # "@@Emisar": Slack.Names already prefixes a resolved user with "@" (and a
    # channel with "#"), and the mention renderer added its own "@" on top.
    # The directory owns the sigil; the renderer only wraps the name.
    start_supervised!({Names, workspace: "T123", fetch: fn _ref -> {:ok, "emisar"} end})
    Names.name("T123", "U1")
    Names.name("T123", "C1")
    # refresh resolves one queued reference per call
    assert :ok = GenServer.call(Names, :refresh)
    assert :ok = GenServer.call(Names, :refresh)

    html = SlackMarkdown.render("<@U1> ping <#C1>", "T123") |> IO.iodata_to_binary()

    assert html =~
             ~s(<a class="kit-person slack-mention" href="https://slack.com/app_redirect?team=T123&amp;channel=U1" target="_blank" rel="noopener noreferrer">@emisar</a>)

    assert html =~ ~s(<span class="slack-mention" title="C1">#emisar</span>)
    refute html =~ "@@"

    assert SlackMarkdown.plain("<@U1> is <#C1> up?", "T123") == "@emisar is #emisar up?"
    assert SlackMarkdown.plain("<@U1> is <#C1> up?", nil) == "<@U1> is <#C1> up?"
  end

  test "directory failures preserve the UI fallback and malformed references never reach Slack" do
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:error, :unavailable}
       end}
    )

    # An unresolved channel still has to tell one row from another. The
    # channels page listed five "Slack channel" rows with the id only in a
    # tooltip, so an operator could not tell #test from #test2 at all.
    assert Names.name("T123", "C789") == "Slack channel C789"

    # A person is never their raw ID (Andrew, 2026-09-26: "Slack user
    # U0BHTNFCW6S" is not readable); their profile link tells two apart.
    assert Names.name("T123", "U789") == "Slack user"

    # A reference Slack would reject is never echoed back into the page.
    assert Names.name("T123", "../../secrets") == "Slack reference"
    assert :ok = GenServer.call(Names, :refresh)
    assert_receive {:lookup, "C789"}
    assert :ok = GenServer.call(Names, :refresh)
    assert_receive {:lookup, "U789"}
    assert Names.name("T123", "U789") == "Slack user"
    assert :ok = GenServer.call(Names, :refresh)
    refute_receive {:lookup, _}
  end

  # "Who can manage Ryker" read "Slack user U0BHTNFCW6S" on 2026-09-26 where
  # Andrew expected his name. A person is shown one way everywhere: their
  # name, linked to their Slack profile, and never a raw ID.
  test "a person reads as their name linked to their Slack profile, never as a raw ID" do
    start_supervised!(
      {Names,
       workspace: "T123",
       workspace_url: "https://acme.slack.com",
       fetch: fn _ref -> {:ok, "Andrew"} end}
    )

    profile = "https://acme.slack.com/team/U456"
    assert Names.person("T123", "U456") == %{name: "Slack user", href: profile}
    assert :ok = GenServer.call(Names, :refresh)
    assert Names.person("T123", "U456") == %{name: "@Andrew", href: profile}
    assert Names.person("T123", "slack:user:U456") == %{name: "@Andrew", href: profile}

    # Without the workspace's address, Slack itself opens the profile.
    assert Names.person("T999", "W456").href ==
             "https://slack.com/app_redirect?team=T999&channel=W456"

    # Nothing Slack would reject is linked or echoed.
    assert Names.person("T123", "../../secrets") == %{name: "Slack user", href: nil}
    assert Names.person(nil, "U456") == %{name: "Slack user", href: nil}
  end

  # The page that asked for a name was drawn before Slack answered, and
  # nothing drew it again: the name only appeared after a reload.
  test "a name found in the background redraws the pages showing it, once per change" do
    :ok = Ryker.PubSub.subscribe("control-plane")
    start_supervised!({Names, workspace: "T123", fetch: fn _ref -> {:ok, "Andrew"} end})

    Names.name("T123", "U456")
    assert :ok = GenServer.call(Names, :refresh)
    assert_receive :control_plane_changed

    # The same name again changes nothing any page shows.
    assert :ok = Names.remember([{"T123", "U456", "Andrew"}])
    refute_receive :control_plane_changed, 50

    assert :ok = Names.remember([{"T123", "U456", "Andy"}])
    assert_receive :control_plane_changed
    assert Names.name("T123", "U456") == "@Andy"

    # Another workspace's people are not this cache's to keep.
    assert :ok = Names.remember([{"T999", "U777", "Eve"}])
    refute_receive :control_plane_changed, 50
    assert Names.name("T999", "U777") == "Slack user"
  end

  test "a late lookup does not refetch a fresh name and rate limits stop queued lookups" do
    parent = self()

    start_supervised!(
      {Names,
       fetch: fn ref ->
         send(parent, {:lookup, ref})

         if ref == "C429",
           do: {:error, {:delivery_rate_limited, 120, :limited}},
           else: {:ok, "test"}
       end,
       workspace: "T123"}
    )

    Names.name("T123", "C456")
    GenServer.call(Names, :refresh)
    assert_receive {:lookup, "C456"}
    GenServer.cast(Names, {:resolve, "T123", "C456"})
    GenServer.call(Names, :refresh)
    refute_receive {:lookup, _}
    Names.name("T123", "C429")
    Names.name("T123", "U789")
    GenServer.call(Names, :refresh)
    assert_receive {:lookup, "C429"}
    GenServer.call(Names, :refresh)
    refute_receive {:lookup, _}
  end

  test "a directory transport exit cannot take down the console" do
    start_supervised!({Names, workspace: "T123", fetch: fn _ -> exit(:timeout) end})
    Names.name("T123", "C456")
    assert :ok = GenServer.call(Names, :refresh)
    assert Names.name("T123", "C456") == "Slack channel C456"
  end

  test "resolved names cannot reintroduce credentials into sanitized request inspection" do
    # Directory names are inserted after the retained request is sanitized.
    # A credential in a profile must not bypass the inspection redaction policy.
    Application.put_env(:ryker, :directory_redaction_test, %{
      token: "configured-private-value"
    })

    on_exit(fn -> Application.delete_env(:ryker, :directory_redaction_test) end)

    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn _ -> {:ok, "Andrew configured-private-value password=hunter2"} end}
    )

    Names.name("T123", "U456")
    GenServer.call(Names, :refresh)

    html =
      %{
        "input" => %{
          "source" => %{"kind" => "slack", "ref" => "T123"},
          "actor" => %{"ref" => "U456"},
          "text" => "Ask <@U456>"
        }
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.render()
      |> IO.iodata_to_binary()

    refute html =~ "configured-private-value"
    refute html =~ "hunter2"
    assert html =~ "Andrew [redacted]"
  end

  # A mention of a person is shown as every person is: their name, linked to
  # their Slack profile, with no raw ID even in a tooltip (Andrew,
  # 2026-09-26). The profile link is how a reader finds out who it is.
  test "a mentioned person reads as their name linked to Slack, a channel keeps its reference" do
    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn ref -> {:ok, if(ref == "U456", do: "Andrew <admin>", else: "test")} end}
    )

    Names.name("T123", "U456")
    Names.name("T123", "C789")
    GenServer.call(Names, :refresh)
    GenServer.call(Names, :refresh)

    html =
      SlackMarkdown.render(
        "Hi <@U456> in <#C789|old-name> `literal <@U456>`",
        "T123"
      )
      |> IO.iodata_to_binary()

    assert html =~ "@Andrew &lt;admin&gt;"
    assert html =~ "#test"
    assert html =~ ~s(href="https://slack.com/app_redirect?team=T123&amp;channel=U456")
    refute html =~ ~s(title="U456")
    assert html =~ ~s(title="C789")
    assert html =~ "<code>literal &lt;@U456&gt;</code>"
    refute html =~ "<admin>"
    assert Names.destination("control_plane:control-plane:lab:uuid") == "Direct conversation"
    assert Names.destination("control-plane:lab:uuid") == "Direct conversation"

    artifact =
      InspectionRedactor.artifact(%{
        "input" => %{
          "source" => %{"kind" => "slack", "ref" => "T123"},
          "actor" => %{"kind" => "user", "ref" => "U456"},
          "content" => %{"text" => "Ask <@U456> in <#C789>"}
        }
      })

    context = RequestContextHTML.render(artifact) |> IO.iodata_to_binary()
    assert context =~ ~s(>@Andrew &lt;admin&gt;</a></strong>)
    assert context =~ "#test"

    title =
      SlackMarkdown.mentions(
        "Hi <@U456> <https://example.test|not a nested link>",
        "T123"
      )
      |> IO.iodata_to_binary()

    assert title =~ "@Andrew &lt;admin&gt;"
    refute title =~ "<a "
  end
end
