defmodule Ryker.ControlPlane.ConversationMemoryTest do
  # The learning page and the request page each read this ref by hand until
  # 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.ConversationMemory

  test "a knowledge source ref opens its topic, and any other ref opens nothing" do
    id = Ecto.UUID.generate()

    assert ConversationMemory.knowledge_path("knowledge:" <> id) ==
             ConversationMemory.topic_path(id)

    assert ConversationMemory.knowledge_path("knowledge:not-a-uuid") == nil
    assert ConversationMemory.knowledge_path("message:1") == nil
  end
end
