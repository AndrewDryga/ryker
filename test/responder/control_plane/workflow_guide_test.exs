defmodule Responder.ControlPlane.WorkflowGuideTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Responder.ControlPlane.{CardLab, WorkflowGuide}

  test "every card family belongs to a discoverable workflow with a valid preview" do
    # A supported feature must not depend on the operator guessing a prompt or URL.
    entries = WorkflowGuide.entries()
    previews = Enum.flat_map(entries, & &1.previews)

    families =
      for %{href: href} <- previews do
        ["card-lab", family, state] = String.split(href, "/", trim: true)
        assert {:ok, _} = CardLab.fetch(family, state)
        family
      end

    assert Enum.sort(families) == Enum.sort(Enum.map(CardLab.catalog(), & &1.id))
    html = render_component(&WorkflowGuide.render/1)
    assert html =~ "What you can do"
    assert html =~ "Memory &amp; continuity"

    for path <-
          ~w(/rules /preferences /guidance /memory /subscriptions /schedules /configuration /channels /repositories /workspaces /incidents /findings) do
      assert html =~ "href=\"#{path}\""
    end

    refute html =~ "<form"
  end
end
