defmodule Responder.ControlPlane.RequestContextHTMLTest do
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.{InspectionRedactor, RequestContextHTML}

  test "message roles and context omissions are readable without making source HTML executable" do
    artifact =
      InspectionRedactor.artifact(%{
        "inputs" => %{
          "items" => [
            %{
              "actor_ref" => "slack:user:U123",
              "current" => true,
              "content" => %{"content" => %{"text" => "Inspect <script>alert('x')</script>"}}
            }
          ],
          "omitted_count" => 3
        }
      })

    html = artifact |> RequestContextHTML.render() |> IO.iodata_to_binary()
    assert html =~ "context-message-body"
    assert html =~ "slack:user:U123"
    assert html =~ "3 earlier inputs were omitted"
    assert html =~ "Inspect &lt;script&gt;"
    refute html =~ "<script>"
  end

  test "an incomplete sanitized artifact is not presented as complete readable context" do
    artifact =
      InspectionRedactor.artifact(%{"input" => %{"text" => String.duplicate("x", 100)}},
        max_bytes: 30
      )

    assert RequestContextHTML.render(artifact) == []
    assert RequestContextHTML.render(InspectionRedactor.artifact(nil, expired: true)) == []

    assert RequestContextHTML.instructions(InspectionRedactor.artifact(nil, expired: true), :work) ==
             []
  end

  test "all retained fields including empty and unfamiliar layers remain source-labelled and escaped" do
    # New context fields previously disappeared from the readable projection.
    artifact =
      InspectionRedactor.artifact(%{
        "records" => [],
        "future.layer" => "<script>opaque</script>",
        "operator_context" => %{"memory" => [], "continuity" => %{}}
      })

    html = artifact |> RequestContextHTML.render("$.work") |> IO.iodata_to_binary()
    assert html =~ "data-source=\"future.layer\""
    assert html =~ "Additional retained field"
    assert html =~ "Empty in request"
    assert html =~ "$.work.operator_context.memory"
    assert html =~ "Conversation summaries"
    assert html =~ "&lt;script&gt;opaque&lt;/script&gt;"
    refute html =~ "<script>"
  end

  test "unexpected retained context shapes remain inspectable instead of crashing the page" do
    for context <- [
          %{"inputs" => %{"items" => nil}},
          %{"candidates" => [nil, "legacy value", %{"state" => %{}, "allowed_relations" => 1}]},
          %{"input" => %{"actor" => %{"kind" => %{}}, "occurred_at" => %{}, "text" => "Hello"}}
        ] do
      artifact = InspectionRedactor.artifact(context)
      assert artifact |> RequestContextHTML.render() |> IO.iodata_to_binary() |> is_binary()
    end
  end
end
