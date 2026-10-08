defmodule Ryker.ControlPlane.KitTest do
  # Chat's reaction controls and the prompt document each derived these ids by
  # hand until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.Kit

  test "content with no ref of its own gets the same DOM id on every render" do
    id = Kit.content_id("lab-reaction", "1712345678.000100:thumbsup")

    assert id == Kit.content_id("lab-reaction", "1712345678.000100:thumbsup")
    assert id =~ ~r/\Alab-reaction-[0-9a-f]{16}\z/
  end
end
