defmodule Responder.InstructionsTest do
  use Responder.DataCase, async: true

  alias Responder.CanonicalJSON
  alias Responder.Instructions
  alias Responder.Instructions.{Edit, Setting}

  @actor "control-plane:local"

  test "empty settings are explicit and inspecting them never writes defaults" do
    assert %{text: "", revision: 0, saved_by: nil, saved_at: nil} = Instructions.get(:global)

    assert Instructions.snapshot(%{transport: "webhook", conversation_ref: "deployment"}) == %{
             "global" => %{"scope" => "global", "revision" => 0, "text" => ""},
             "channel" => nil
           }

    assert Repo.aggregate(Setting, :count) == 0
    assert Repo.aggregate(Edit, :count) == 0
  end

  test "global and bound-channel text are captured together without importing another channel" do
    assert {:ok, %{revision: 1}} = Instructions.save(:global, "Keep replies concise.", 0, @actor)

    assert {:ok, %{revision: 1}} =
             Instructions.save(
               {:channel, "T1", "C1"},
               "Explain database checks.\nKeep evidence.",
               0,
               @actor
             )

    assert {:ok, _} =
             Instructions.save({:channel, "T1", "C2"}, "Private other channel.", 0, @actor)

    assert {:ok, _} = Instructions.save({:channel, "T2", "C1"}, "Other workspace.", 0, @actor)

    snapshot = Instructions.snapshot(%{transport: "slack", conversation_ref: "slack:T1:C1"})
    assert snapshot["global"]["text"] == "Keep replies concise."

    assert snapshot["channel"] == %{
             "scope" => "slack:T1:C1",
             "revision" => 1,
             "text" => "Explain database checks.\nKeep evidence."
           }

    refute inspect(snapshot) =~ "Private other channel"
    refute inspect(snapshot) =~ "Other workspace"

    assert Instructions.snapshot(%{transport: "webhook", conversation_ref: "slack:T1:C1"})[
             "channel"
           ] == nil

    assert Instructions.snapshot(%{transport: "slack", conversation_ref: "slack:T1:C3"})[
             "channel"
           ] == %{"scope" => "slack:T1:C3", "revision" => 0, "text" => ""}
  end

  test "stale edits cannot replace current text and identical saves do not create revisions" do
    assert {:ok, first} = Instructions.save(:global, "First instructions", 0, @actor)
    assert first.saved_by == @actor
    assert %DateTime{} = first.saved_at
    assert {:ok, ^first} = Instructions.save(:global, "First instructions", 1, @actor)

    assert {:error, {:instructions_conflict, current}} =
             Instructions.save(:global, "Stale tab", 0, @actor)

    assert current.text == "First instructions"
    assert current.revision == 1
    assert Instructions.get(:global) == first
    assert Repo.aggregate(Edit, :count) == 1
  end

  test "clearing and re-adding keep monotonic identity and clear only the selected scope" do
    channel = {:channel, "T1", "C1"}
    assert {:ok, _} = Instructions.save(:global, "Global", 0, @actor)
    assert {:ok, first} = Instructions.save(channel, "Channel", 0, @actor)
    assert {:ok, cleared} = Instructions.save(channel, " \n\t ", first.revision, @actor)
    assert cleared.text == ""
    assert cleared.revision == 2
    assert {:ok, ^cleared} = Instructions.save(channel, "", 2, @actor)
    assert {:ok, restored} = Instructions.save(channel, "Channel again", 2, @actor)
    assert restored.revision == 3
    assert restored.scope_ref == first.scope_ref

    assert {:ok, _} = Instructions.save(:global, "", 1, @actor)
    snapshot = Instructions.snapshot(%{transport: "slack", conversation_ref: "slack:T1:C1"})
    assert snapshot["global"]["text"] == ""
    assert snapshot["channel"]["text"] == "Channel again"
  end

  test "Unicode and Markdown remain intact while character and byte limits are enforced separately" do
    text = "    Keep indentation\r\n**Important**: café 👩‍💻"
    assert {:ok, saved} = Instructions.save(:global, text, 0, @actor)
    assert saved.text == String.replace(text, "\r\n", "\n")

    assert {:ok, _} =
             Instructions.save(:global, String.duplicate("e\u0301", 2_000), 1, @actor)

    for {text, reason} <- [
          {String.duplicate("a", 2_001), :characters},
          {String.duplicate("e\u0301\u0301\u0301", 2_000), :bytes}
        ] do
      assert {:error, {:invalid_instructions, ^reason}} =
               Instructions.save(:global, text, 2, @actor)
    end

    assert Instructions.get(:global).revision == 2
  end

  test "edit provenance records revision and actor without keeping a second copy of removed text" do
    assert {:ok, saved} = Instructions.save(:global, "Private steering", 0, @actor)
    [edit] = Repo.all(Edit)
    assert edit.scope_ref == saved.scope_ref
    assert edit.revision == saved.revision
    assert edit.actor_ref == @actor
    assert edit.text_fingerprint == CanonicalJSON.digest(saved.text)
    refute Map.has_key?(edit, :text)
    assert {:ok, _} = Instructions.save(:global, "", 1, @actor)
    assert Enum.map(Repo.all(Edit), & &1.revision) |> Enum.sort() == [1, 2]
  end

  test "invalid scopes and edit metadata never create settings" do
    for scope <- [:workspace, {:channel, "T1", "C1:other"}, {:channel, "", "C1"}] do
      assert {:error, {:invalid_instructions, :scope}} =
               Instructions.save(scope, "Text", 0, @actor)
    end

    assert {:error, {:invalid_instructions, :revision}} =
             Instructions.save(:global, "Text", -1, @actor)

    assert {:error, {:invalid_instructions, :actor}} = Instructions.save(:global, "Text", 0, "")
    assert Repo.aggregate(Setting, :count) == 0
  end
end
