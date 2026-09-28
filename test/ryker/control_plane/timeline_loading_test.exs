defmodule Ryker.ControlPlane.TimelineLoadingTest do
  @moduledoc """
  What the Timeline pays for on every refresh, and what a reader can still reach.

  A tool-heavy run records hundreds of calls. Every result body was sanitized
  and re-encoded on every refresh, for text that is almost always closed, and
  the cost lands on the page an operator opens while an incident is running.
  Result bodies now load when their disclosure opens. Arguments do not: the
  compact row a reader scans is derived from them, so making those lazy would
  empty the face instead of the body.

  Retained history is bounded rather than endless, and saying so is part of the
  contract: the page states how much of the retained total it is showing and
  loads older events in explicit, bounded steps that neither drop nor duplicate
  the rows already read.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Activity, ActivityEvent, Custody, Submission}

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "an unopened tool result does not reach the reader's document" do
    small = episode_with_tool!("small", String.duplicate("a", 200))
    large = episode_with_tool!("large", String.duplicate("a", 150_000))

    assert loaded_bytes(large) == loaded_bytes(small),
           "a result body nobody opened must not reach the reader's document"

    body = tool_body(large, "output")
    assert body.artifact.state == :collapsed
    assert body.artifact.text == nil
    assert body.artifact.bytes >= 150_000
  end

  test "opening one result body prepares that body and no other" do
    work = episode_with_tool!("opened", String.duplicate("b", 40_000))
    id = tool_body(work, "output").artifact_id
    assert is_binary(id)

    opened = tool_body(work, "output", [id])
    assert opened.artifact.state == :retained
    assert opened.artifact.text =~ "bbbb"

    assert tool_body(work, "content", [id]).artifact.state == :collapsed
  end

  test "arguments stay prepared so the card face keeps its command" do
    work = episode_with_tool!("arguments", String.duplicate("c", 5_000))
    arguments = tool_body(work, "input")

    assert arguments.artifact.state == :retained
    assert arguments[:artifact_id] == nil
    assert rendered(work) =~ "rg --files"
  end

  test "an expired tool body closes instead of keeping the reader's copy" do
    work = episode_with_tool!("expired", String.duplicate("d", 40_000))
    id = tool_body(work, "output").artifact_id

    Repo.update_all(from(event in ActivityEvent, where: event.episode_id == ^work.episode.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    html = rendered(work, [id])
    refute html =~ String.duplicate("d", 200)
  end

  test "loading earlier activity adds older events without losing the newest" do
    work = episode_with_tool!("pagination", "small")
    filler!(work, 1_020)

    first = Activity.page_for_episode(work.episode.id)
    assert first.shown == 1_000
    assert first.total == 1_021
    assert first.truncated

    second = Activity.page_for_episode(work.episode.id, 2)
    assert second.shown == 1_021
    refute second.truncated

    newest = List.last(first.events).id
    assert List.last(second.events).id == newest
    assert MapSet.subset?(ids(first.events), ids(second.events))

    {:ok, page_one} = EpisodeProjection.fetch(work.episode.key)
    assert page_one.trace.activity.more == 2

    {:ok, page_two} = EpisodeProjection.fetch(work.episode.key, %{"events" => "2"})
    assert page_two.trace.activity.more == nil
    assert rendered(work) =~ "Show earlier activity"
  end

  test "every card offers a link built from its own durable identity" do
    work = episode_with_tool!("links", "small")
    document = LazyHTML.from_document(rendered(work))

    links =
      document
      |> LazyHTML.query(".case-entry")
      |> Enum.map(fn entry ->
        [id] = LazyHTML.attribute(entry, "id")
        [href] = entry |> LazyHTML.query(".card-link") |> LazyHTML.attribute("href")
        {id, href}
      end)

    assert links != []
    assert Enum.all?(links, fn {id, href} -> href == "##{id}" end)

    # The identity is the evidence key, never the reader's position in the page.
    assert Enum.any?(links, fn {id, _href} -> String.starts_with?(id, "event-activity-") end)
  end

  test "worker startup diagnostics read as setup instead of user-requested tool work" do
    work = episode_with_tool!("mcp-startup", "ready")

    [event] = Repo.all(from(event in ActivityEvent, where: event.episode_id == ^work.episode.id))

    payload =
      event.payload
      |> Map.put("title", "mcp_startup.github")
      |> Map.put("input", %{"operation" => "mcp_startup.github"})

    Repo.update_all(from(saved in ActivityEvent, where: saved.id == ^event.id),
      set: [payload: payload, payload_fingerprint: CanonicalJSON.digest(payload)]
    )

    document = work |> rendered() |> LazyHTML.from_document()

    assert LazyHTML.query(document, ".case-event-content h3") |> LazyHTML.text() =~
             "Github connection setup"

    assert Enum.empty?(LazyHTML.query(document, ".tool-card"))
  end

  # Andrew, 2026-09-28: "nice design for every kind, branded cards for Emisar
  # tool calls, informative cards, consecutive calls collapsed into one card
  # where it fits (like queues)". One infrastructure review drew a card per
  # call, some 43,000 pixels. Calls that follow each other are one card now,
  # a line per step that opens to its full card; a call that failed keeps a
  # card of its own.
  test "consecutive tool calls read as one card, a line per step, Emisar's with its mark" do
    work = episode_with_tool!("run", "small")

    tool!(work, 2, "find_actions", %{"query" => "gcp compute instances list"})
    tool!(work, 3, "list_runners", %{})
    tool!(work, 4, "get_work_state", %{})
    tool!(work, 5, "list_packs", %{}, "failed")

    document = LazyHTML.from_document(rendered(work))
    [run] = document |> LazyHTML.query(".case-tool_run") |> Enum.to_list()

    assert LazyHTML.query(run, ".tool-run > .case-card-heading h3") |> LazyHTML.text() ==
             "4 steps"

    lines =
      run
      |> LazyHTML.query(".tool-run-step")
      |> Enum.map(fn step ->
        {LazyHTML.query(step, ".tool-run-badge") |> LazyHTML.text() |> String.trim(),
         LazyHTML.query(step, ".tool-run-title") |> LazyHTML.text(),
         LazyHTML.query(step, ".tool-run-text") |> LazyHTML.text()}
      end)

    assert lines == [
             {"Code", "Run command", "rg --files"},
             {"Emisar", "Emisar actions looked up", "gcp compute instances list"},
             {"Emisar", "Emisar runners listed", ""},
             {"Ryker", "Work state read", ""}
           ]

    assert LazyHTML.query(run, ".tool-run-badge[data-service=emisar] svg.emisar-mark")
           |> Enum.count() == 2

    # Each step keeps its own anchor and opens to its full card.
    assert run
           |> LazyHTML.query("li.tool-run-step")
           |> LazyHTML.attribute("id")
           |> Enum.all?(&String.starts_with?(&1, "event-activity-"))

    assert LazyHTML.query(run, "details.tool-run-detail .tool-run-body .action-card")
           |> Enum.count() == 4

    # The failed call is a card of its own after the run.
    failed =
      document |> LazyHTML.query(".case-entry:not(.case-tool_run) .action-card") |> Enum.to_list()

    assert Enum.any?(failed, &(LazyHTML.text(&1) =~ "failed"))
  end

  defp tool!(work, sequence, tool, arguments, status \\ "completed") do
    payload = %{
      "evidence_version" => 1,
      "kind" => "other",
      "tool_call_id" => "call-#{tool}-#{sequence}",
      "title" => tool,
      "input" => %{"server" => "controller-tools", "tool" => tool, "arguments" => arguments},
      "status" => status
    }

    Repo.insert!(%ActivityEvent{
      coop_turn_id: "coop-turn-run",
      episode_id: work.episode.id,
      kind: "tool.completed",
      occurred_at: DateTime.add(@now, 90 + sequence, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "tool-event:run:#{sequence}",
      remote_session_id: "remote-session:#{work.session.id}",
      sequence: sequence,
      session_id: work.session.id,
      version: 1
    })
  end

  defp ids(events), do: MapSet.new(events, & &1.id)

  defp loaded_bytes(work) do
    {:ok, detail} = EpisodeProjection.fetch(work.episode.key)

    detail.trace.steps
    |> Enum.flat_map(&(&1[:artifacts] || []))
    |> Enum.map(&byte_size(&1.artifact.text || ""))
    |> Enum.sum()
  end

  defp tool_body(work, key, disclosed \\ []) do
    {:ok, detail} = EpisodeProjection.fetch(work.episode.key, %{"disclosed" => disclosed})

    detail.trace.steps
    |> Enum.flat_map(&(&1[:artifacts] || []))
    |> Enum.find(&(&1.label == label(key)))
  end

  defp label("input"), do: "Arguments"
  defp label("output"), do: "Response"
  defp label("content"), do: "Output and changes"

  defp rendered(work, disclosed \\ []) do
    {:ok, detail} = EpisodeProjection.fetch(work.episode.key, %{"disclosed" => disclosed})
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp filler!(work, count) do
    now = DateTime.utc_now()

    rows =
      for index <- 1..count do
        payload = %{"text" => "progress #{index}"}

        %{
          id: Ecto.UUID.generate(),
          episode_id: work.episode.id,
          session_id: work.session.id,
          kind: "model.progress",
          occurred_at: DateTime.add(now, -index, :second),
          payload: payload,
          payload_fingerprint: CanonicalJSON.digest(payload),
          remote_event_id: "filler:#{index}",
          remote_session_id: "remote:#{work.session.id}",
          sequence: 1_000 + index,
          version: 1,
          inserted_at: now
        }
      end

    Repo.insert_all(ActivityEvent, rows)
  end

  defp episode_with_tool!(suffix, output) do
    episode_id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "timeline-loading:#{suffix}:#{episode_id}",
          native_input_id: "source:#{suffix}:#{episode_id}",
          turn_ref: "turn:#{suffix}:#{episode_id}"
        })
      )

    {:ok, session} = Custody.pin_episode(episode_id, "loading", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("loading:#{suffix}", 120, :work)

    {:ok, submission} =
      Submission.new(
        %{"mode" => "full"},
        "Investigate",
        %{"type" => "object"},
        "work-final-live-v3"
      )

    {:ok, _frozen} =
      Custody.freeze_submission(episode_id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        episode_id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        1,
        "coop-session-#{suffix}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        episode_id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        1,
        "coop-turn-#{suffix}"
      )

    payload = %{
      "evidence_version" => 1,
      "kind" => "command",
      "tool_call_id" => "call-#{suffix}",
      "title" => "Run command",
      "input" => %{"command" => "rg --files", "server" => "shell"},
      "output" => output,
      "content" => String.duplicate("f", 30_000),
      "status" => "completed"
    }

    Repo.insert!(%ActivityEvent{
      coop_turn_id: "coop-turn-#{suffix}",
      episode_id: episode_id,
      kind: "tool.completed",
      occurred_at: DateTime.add(@now, 90, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "tool-event:#{suffix}",
      remote_session_id: "remote-session:#{session.id}",
      sequence: 1,
      session_id: session.id,
      version: 1
    })

    %{episode: episode, session: session, turn: turn}
  end
end
