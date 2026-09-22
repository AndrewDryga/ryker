defmodule Ryker.ControlPlane.ExecutionTargetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Components, ExecutionTarget}

  test "the co:op target is presented as labelled human information" do
    assert ExecutionTarget.present("codex:gpt-5.6-sol/medium@default") == %{
             canonical: "codex:gpt-5.6-sol/medium@default",
             model: "gpt-5.6-sol",
             meta: "Medium reasoning · Codex · Default profile",
             compact: "gpt-5.6-sol · Medium reasoning · Codex · Default profile",
             parts: %{
               provider: "codex",
               model: "gpt-5.6-sol",
               effort: "medium",
               profile: "default"
             }
           }

    html =
      render_component(&Components.execution_target/1,
        target: "codex:gpt-5.6-sol/medium@default"
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, ".execution-target-model") |> LazyHTML.text() == "gpt-5.6-sol"

    assert LazyHTML.query(document, ".execution-target-meta") |> LazyHTML.text() ==
             "Medium reasoning · Codex · Default profile"

    assert LazyHTML.query(document, ".execution-target") |> LazyHTML.attribute("title") == [
             "codex:gpt-5.6-sol/medium@default"
           ]
  end

  test "missing and noncanonical targets are reported without invented parts" do
    assert ExecutionTarget.present(nil).model == "Model not recorded"

    assert ExecutionTarget.present("Execution target not recorded") == %{
             canonical: "Execution target not recorded",
             model: "Execution target not recorded",
             meta: nil,
             compact: "Execution target not recorded",
             parts: nil
           }
  end
end
