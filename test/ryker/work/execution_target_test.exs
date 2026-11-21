defmodule Ryker.Work.ExecutionTargetTest do
  use ExUnit.Case, async: true
  alias Ryker.Work.ExecutionTarget

  test "the co:op target is presented as labelled human information" do
    assert ExecutionTarget.present("codex:gpt-5.6-sol/medium@default") == %{
             canonical: "codex:gpt-5.6-sol/medium@default",
             model: "gpt-5.6-sol",
             meta: "Medium reasoning · Codex · Default account",
             compact: "gpt-5.6-sol · Medium reasoning · Codex · Default account",
             parts: %{
               provider: "codex",
               model: "gpt-5.6-sol",
               effort: "medium",
               fast: false,
               account: "default"
             }
           }
  end

  # Andrew, 2026-11-21: "can we also allow using fast mode?" Coop takes the provider's fast
  # mode as +fast after the effort; it is said in words, and the effort stays the effort.
  test "a target in fast mode keeps its effort and says it runs fast" do
    presented = ExecutionTarget.present("codex:gpt-6.2-sol/medium+fast@default")
    assert presented.parts.effort == "medium"
    assert presented.parts.fast
    assert presented.meta == "Medium reasoning · Fast mode · Codex · Default account"
  end

  # A kind of work saves its model and then the fallbacks Coop moves to when
  # the one above hits a usage limit. Settings shows a saved list in one line,
  # in the order Coop tries it, and keeps the list as Coop writes a ladder.
  test "a saved fallback list reads as its first model, then each fallback in order" do
    presented =
      ExecutionTarget.present([
        "codex:gpt-5.6-sol/medium@default",
        "claude:claude-opus-4-6/high@work"
      ])

    assert presented.model == "gpt-5.6-sol"

    assert presented.canonical ==
             "codex:gpt-5.6-sol/medium@default claude:claude-opus-4-6/high@work"

    assert presented.compact ==
             "gpt-5.6-sol · Medium reasoning · Codex · Default account, then " <>
               "claude-opus-4-6 · High reasoning · Claude · Work account"

    assert ExecutionTarget.present(["codex:gpt-5.6-sol/medium@default"]) ==
             ExecutionTarget.present("codex:gpt-5.6-sol/medium@default")
  end

  test "missing and noncanonical targets are reported without invented parts" do
    assert ExecutionTarget.present(nil).model == "Model not recorded"
    assert ExecutionTarget.present([]).model == "Model not recorded"

    assert ExecutionTarget.present("Execution target not recorded") == %{
             canonical: "Execution target not recorded",
             model: "Execution target not recorded",
             meta: nil,
             compact: "Execution target not recorded",
             parts: nil
           }
  end
end
