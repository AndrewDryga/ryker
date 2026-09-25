defmodule Ryker.ControlPlane.LabPageTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.LabPage

  @now ~U[2026-09-13 14:32:00Z]

  # In the order the page groups them since 2026-09-19: Investigate, Build, Remember.
  @examples [
    "Investigate why this service keeps restarting.",
    "Summarize the attached log and identify likely causes.",
    "Ask me three questions to clarify this investigation.",
    "Review this change for bugs and missing tests.",
    "Help me turn this issue into an engineering task.",
    "Compare these two approaches and explain the trade-offs.",
    "Generate a small illustration of a rocket launch.",
    "Remind me tomorrow at 9:00 to check the deployment.",
    "Remember that I prefer concise incident updates.",
    "Show the automations active in this conversation."
  ]

  test "the placeholder pool is exactly the ten authored examples" do
    # Andrew approved these ten strings on 2026-09-09. They are UI copy, not
    # model fixtures: a generated or paraphrased eleventh example, or a missing
    # one, changes what an operator is invited to type.
    assert LabPage.examples() == @examples
    assert LabPage.random_example() in @examples
  end

  test "an open conversation keeps one example across every render of the same view" do
    # The composer is a phx-update=ignore form, so the placeholder the browser
    # shows is whatever the first render carried. If the pick changed on every
    # render, a reconnect would replace the server's idea of the hint while the
    # browser kept the old one, and tests could not say which one is live.
    id = Ecto.UUID.generate()
    assert LabPage.example_for(id) == LabPage.example_for(id)
    assert LabPage.example_for(id) in @examples

    picks = Enum.map(1..200, fn _ -> LabPage.example_for(Ecto.UUID.generate()) end)
    assert length(Enum.uniq(picks)) > 1
  end

  test "the directory groups conversations by recency in one labelled timezone" do
    # Sept 13: the old list showed "3 inputs · 13 Sep, 12:58 UTC" on every row
    # and no grouping, so today's conversation and one from last week read the
    # same. Group labels come from the observed clock, times stay UTC, and a
    # row keeps its position inside its group.
    items = [
      %{id: "a", title: "Read the automations", updated_at: ~U[2026-09-13 04:12:00Z]},
      %{id: "b", title: "Read the automations", updated_at: ~U[2026-09-13 03:54:00Z]},
      %{id: "c", title: "Yesterday's thread", updated_at: ~U[2026-09-12 23:59:00Z]},
      %{
        id: "d",
        title: "Check why Livebook has zero instances",
        updated_at: ~U[2026-09-06 23:04:00Z]
      }
    ]

    assert [
             {"Today", [%{id: "a"}, %{id: "b"}]},
             {"Yesterday", [%{id: "c"}]},
             {"Earlier", [%{id: "d"}]}
           ] = LabPage.directory_groups(items, @now)

    assert LabPage.directory_time(~U[2026-09-13 04:12:00Z], @now) == "04:12 UTC"
    assert LabPage.directory_time(~U[2026-09-12 23:59:00Z], @now) == "12 Sep, 23:59 UTC"
    assert LabPage.directory_time(~U[2026-09-06 23:04:00Z], @now) == "06 Sep, 23:04 UTC"
    assert LabPage.directory_groups([], @now) == []
  end

  test "a message's timeline link resolves only its own retained execution" do
    # The runtime rail linked "All requests in this conversation" and the
    # latest episode; a message from an earlier episode had no way to its own
    # execution. Each link now comes from the message's exact input id or
    # producing turn, never from list position, title text or the newest episode.
    pending = %{actor: :operator, input_id: "0193", episode_id: nil, status: :pending}
    assert LabPage.timeline_href(pending) == "/timeline/ingress-input%3A0193"

    assert LabPage.timeline_href(%{pending | status: :blocked}) ==
             "/timeline/ingress-input%3A0193"

    admitted = %{
      actor: :operator,
      input_id: "0193",
      episode_id: "episode-uuid",
      status: :decided,
      decision_action: :start_episode
    }

    # Once routed, the same route is this input's own admission request on its
    # episode; an ignored input's is its recorded decision.
    assert LabPage.timeline_href(admitted) == "/timeline/ingress-input%3A0193"

    assert LabPage.timeline_href(%{admitted | episode_id: nil, decision_action: :ignore}) ==
             "/timeline/ingress-input%3A0193"

    integration = %{actor: :integration, input_id: "0194", episode_id: nil, status: :pending}
    assert LabPage.timeline_href(integration) == "/timeline/ingress-input%3A0194"

    reply = %{
      actor: :ryker,
      episode_ref: "conversation-lab:abc",
      turn_id: "turn-uuid",
      status: :settled
    }

    assert LabPage.timeline_href(reply) ==
             "/timeline/conversation-lab%3Aabc?attempt=turn-uuid#request-turn-uuid"

    action = %{actor: :ryker, episode_ref: "grafana:rule-1:cycle-1", status: :delivered}
    assert LabPage.timeline_href(action) == "/timeline/grafana%3Arule-1%3Acycle-1"

    # No provenance, no guessed URL.
    assert LabPage.timeline_href(%{actor: :ryker, status: :delivered, text: "hi"}) == nil
    assert LabPage.timeline_href(%{actor: :operator, status: :decided, text: "hi"}) == nil
  end
end
