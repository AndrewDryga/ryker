defmodule Responder.ControlPlane.SlackNamesTest do
  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.ControlPlane.RequestContextHTML
  alias Responder.ControlPlane.SlackMarkdown
  use ExUnit.Case, async: false
  alias Responder.ControlPlane.SlackNames

  test "names are scoped to the configured workspace and unavailable names do not block rendering" do
    parent = self()

    start_supervised!(
      {SlackNames,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:ok, "test"}
       end}
    )

    assert SlackNames.name("T123", "C456") == "Slack channel"
    assert SlackNames.name("T999", "C456") == "Slack channel"
    assert :ok = GenServer.call(SlackNames, :refresh)
    assert_receive {:lookup, "C456"}
    assert SlackNames.name("T123", "C456") == "#test"
    assert SlackNames.name("T999", "C456") == "Slack channel"
    assert SlackNames.destination("slack:T123:C456") == "#test"
    refute_receive {:lookup, "C456"}
  end

  test "directory failures preserve the UI fallback and malformed references never reach Slack" do
    parent = self()

    start_supervised!(
      {SlackNames,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:error, :unavailable}
       end}
    )

    assert SlackNames.name("T123", "U789") == "Slack member"
    assert SlackNames.name("T123", "../../secrets") == "Slack reference"
    assert :ok = GenServer.call(SlackNames, :refresh)
    assert_receive {:lookup, "U789"}
    assert SlackNames.name("T123", "U789") == "Slack member"
    assert :ok = GenServer.call(SlackNames, :refresh)
    refute_receive {:lookup, _}
  end

  test "a late lookup does not refetch a fresh name and rate limits stop queued lookups" do
    parent = self()

    start_supervised!(
      {SlackNames,
       fetch: fn ref ->
         send(parent, {:lookup, ref})

         if ref == "C429",
           do: {:error, {:delivery_rate_limited, 120, :limited}},
           else: {:ok, "test"}
       end,
       workspace: "T123"}
    )

    SlackNames.name("T123", "C456")
    GenServer.call(SlackNames, :refresh)
    assert_receive {:lookup, "C456"}
    GenServer.cast(SlackNames, {:resolve, "T123", "C456"})
    GenServer.call(SlackNames, :refresh)
    refute_receive {:lookup, _}
    SlackNames.name("T123", "C429")
    SlackNames.name("T123", "U789")
    GenServer.call(SlackNames, :refresh)
    assert_receive {:lookup, "C429"}
    GenServer.call(SlackNames, :refresh)
    refute_receive {:lookup, _}
  end

  test "a directory transport exit cannot take down the console" do
    start_supervised!({SlackNames, workspace: "T123", fetch: fn _ -> exit(:timeout) end})
    SlackNames.name("T123", "C456")
    assert :ok = GenServer.call(SlackNames, :refresh)
    assert SlackNames.name("T123", "C456") == "Slack channel"
  end

  test "resolved names cannot reintroduce credentials into sanitized request inspection" do
    # Directory names are inserted after the retained request is sanitized.
    # A credential in a profile must not bypass the inspection redaction policy.
    Application.put_env(:responder, :directory_redaction_test, %{
      token: "configured-private-value"
    })

    on_exit(fn -> Application.delete_env(:responder, :directory_redaction_test) end)

    start_supervised!(
      {SlackNames,
       workspace: "T123",
       fetch: fn _ -> {:ok, "Andrew configured-private-value password=hunter2"} end}
    )

    SlackNames.name("T123", "U456")
    GenServer.call(SlackNames, :refresh)

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

  test "mentions use workspace-scoped names while raw identities remain inspectable" do
    start_supervised!(
      {SlackNames,
       workspace: "T123",
       fetch: fn ref -> {:ok, if(ref == "U456", do: "Andrew <admin>", else: "test")} end}
    )

    SlackNames.name("T123", "U456")
    SlackNames.name("T123", "C789")
    GenServer.call(SlackNames, :refresh)
    GenServer.call(SlackNames, :refresh)

    html =
      SlackMarkdown.render(
        "Hi <@U456> in <#C789|old-name> `literal <@U456>`",
        "T123"
      )
      |> IO.iodata_to_binary()

    assert html =~ "@Andrew &lt;admin&gt;"
    assert html =~ "#test"
    assert html =~ "title=\"U456\""
    assert html =~ "<code>literal &lt;@U456&gt;</code>"
    refute html =~ "<admin>"
    assert SlackNames.destination("control_plane:control-plane:lab:uuid") == "Conversation Lab"

    artifact =
      InspectionRedactor.artifact(%{
        "input" => %{
          "source" => %{"kind" => "slack", "ref" => "T123"},
          "actor" => %{"kind" => "user", "ref" => "U456"},
          "content" => %{"text" => "Ask <@U456> in <#C789>"}
        }
      })

    context = RequestContextHTML.render(artifact) |> IO.iodata_to_binary()
    assert context =~ "<strong>Andrew &lt;admin&gt;</strong>"
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
