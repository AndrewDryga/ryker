defmodule Ryker.ControlPlane.RequestContextNamesTest do
  @moduledoc """
  A request's briefing names the people and channels its messages mention.
  It starts the Slack name cache, which is one per node, so it runs alone.
  """
  use ExUnit.Case, async: false

  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.InspectionRedactor
  alias Ryker.Slack.Names

  # Andrew, 2026-09-28: "always render usernames and channel names, not Slack
  # ids". Routing reads earlier messages as actor, at and text alone, so the
  # briefing showed "<@U0C1LCVNF52> check health of our infra" as written.
  test "an earlier message routing read names the people and channels it mentions" do
    start_supervised!({Names, workspace: "T0BHXKZJVDX", fetch: fn _ref -> {:ok, "test"} end})

    :ok =
      Names.remember([
        {"T0BHXKZJVDX", "U0C1LCVNF52", "Ryker"},
        {"T0BHXKZJVDX", "C0BLU1GACKC", "test"}
      ])

    document =
      %{
        "conversation_context" => %{
          "messages" => [
            %{
              "actor" => "U0BHTNFCW6S",
              "at" => "2026-09-27T10:15:46Z",
              "text" => "<@U0C1LCVNF52> check health of our infra in <#C0BLU1GACKC>"
            }
          ]
        }
      }
      |> InspectionRedactor.artifact()
      |> RequestContextHTML.assembly("$.context", "earlier")
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    body = document |> LazyHTML.query(".ui-message-body") |> LazyHTML.text()
    assert body =~ "@Ryker check health of our infra in #test"
    refute body =~ "U0C1LCVNF52"
    refute body =~ "C0BLU1GACKC"
  end
end
