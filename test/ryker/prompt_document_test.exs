defmodule Ryker.PromptDocumentTest do
  # Admission, self-analysis and repository reading each rendered their prompt
  # with a copy of this code until 2026-10-08; only the key order differed.
  use ExUnit.Case, async: true
  alias Ryker.PromptDocument

  test "the instructions lead, then the context in the order given, then the rest alphabetically" do
    prompt = %{
      "context" => %{"zeta" => 1, "input" => "hi", "alpha" => [true], "repository" => "r"},
      "instructions" => "Read it."
    }

    assert PromptDocument.render(prompt, ["repository", "input"]) ==
             ~s({"instructions":"Read it.","context":{"repository":"r","input":"hi","alpha":[true],"zeta":1}})
  end

  test "what was left out is listed once" do
    context = %{"omitted" => []}
    noted = PromptDocument.omit(context, "The oldest messages, left out for length.")

    assert noted == %{"omitted" => ["The oldest messages, left out for length."]}
    assert PromptDocument.omit(noted, "The oldest messages, left out for length.") == noted
  end
end
