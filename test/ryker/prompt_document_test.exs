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

  # Self-analysis and repository reading each cut a long text for the model
  # with their own copy of this until 2026-10-08.
  test "a cut keeps whole characters within its bytes and tells the model the rest is gone" do
    assert PromptDocument.cut("abcdef", 3) == "abc …[cut]"
    assert PromptDocument.cut("ééé", 5) == "éé …[cut]"
  end

  test "what was left out is listed once" do
    context = %{"omitted" => []}
    noted = PromptDocument.omit(context, "The oldest messages, left out for length.")

    assert noted == %{"omitted" => ["The oldest messages, left out for length."]}
    assert PromptDocument.omit(noted, "The oldest messages, left out for length.") == noted
  end

  # Self-analysis and repository reading each fitted their prompt with a copy
  # of this loop until 2026-10-08.
  test "a prompt is made smaller step by step until it fits, and a step that stops shrinking is done" do
    context = %{"notes" => String.duplicate("a", 500), "list" => Enum.to_list(1..100)}

    halve = fn %{"notes" => notes} = context ->
      %{context | "notes" => binary_part(notes, 0, div(byte_size(notes), 2))}
    end

    drop = fn %{"list" => list} = context -> %{context | "list" => Enum.drop(list, 10)} end

    fitted = PromptDocument.fit("Read it.", context, 200, [halve, drop])

    assert PromptDocument.fits?("Read it.", fitted, 200)
    assert fitted["notes"] == ""
    assert length(fitted["list"]) < 100
    refute PromptDocument.fits?("Read it.", context, 200)
  end
end
