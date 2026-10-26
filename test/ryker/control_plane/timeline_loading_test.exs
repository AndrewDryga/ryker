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
  alias Ryker.Fixtures.WorkSessions
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

  test "a closed file read names the reported file and keeps its boundary warning visible" do
    # The retained runbook read showed only 'Read file'; discovering its path
    # needed three disclosures, while its boundary warning was hidden inside.
    work = episode_with_tool!("visible-file", "small")

    activity!(work, 2, "tool.completed", %{
      "kind" => "read",
      "title" => "Read file",
      "status" => "completed",
      "locations" => [%{"path" => "/workspace/.agent/kb/runbooks/deployment.md"}],
      "path_context" => %{
        "basis" => "lexical",
        "paths" => [%{"source" => "/locations/0/path", "scope" => "outside"}]
      }
    })

    document = work |> rendered() |> LazyHTML.from_document()
    row = LazyHTML.query(document, "#event-activity-#{event_id(work, 2)}")
    summary = LazyHTML.query(row, ".tool-run-detail > summary")
    assert LazyHTML.text(summary) =~ "/workspace/.agent/kb/runbooks/deployment.md"
    assert LazyHTML.query(summary, ".tool-run-warning") |> LazyHTML.text() =~ "Outside project"
    assert Enum.empty?(LazyHTML.query(row, ".tool-run-detail[open]"))
    assert Enum.empty?(LazyHTML.query(row, ".action-technical"))
    assert Enum.count(LazyHTML.query(row, ".action-card > .action-raw[data-artifact]")) == 1
    assert Enum.empty?(LazyHTML.query(row, ".action-raw pre"))
  end

  test "a failed call stays closed with the useful error visible above its raw evidence" do
    # The saved-knowledge failure opened itself and hid all seven missing
    # fields below a generic explanation and two more disclosure levels.
    work = episode_with_tool!("visible-failure", "small")

    activity!(work, 2, "tool.completed", %{
      "kind" => "other",
      "title" => "search_memory",
      "status" => "failed",
      "input" => %{
        "server" => "controller-tools",
        "tool" => "search_memory",
        "arguments" => %{"query" => "project region infrastructure"}
      },
      "error" =>
        "invalid_arguments: 7 issues. /after (required): is required. /before (required): is required. /cursor (required): is required. /kinds (required): is required. /limit (required): is required. /scope (required): is required. /time_basis (required): is required. Nothing was changed; correct these fields and call again."
    })

    document = work |> rendered() |> LazyHTML.from_document()
    row = LazyHTML.query(document, "#event-activity-#{event_id(work, 2)}")
    assert Enum.empty?(LazyHTML.query(row, ".tool-run-detail[open]"))

    assert LazyHTML.query(row, ".tool-run-detail > summary .tool-run-error") |> LazyHTML.text() ==
             "Missing required arguments: after, before, cursor, kinds, limit, scope, time_basis."

    assert Enum.empty?(LazyHTML.query(row, ".action-technical"))
    assert Enum.count(LazyHTML.query(row, ".action-card > .action-raw")) == 2
    assert Enum.empty?(LazyHTML.query(row, ".action-raw[data-artifact] pre"))
  end

  test "compact path and failure evidence respects withholding, redaction and bounded display" do
    work = episode_with_tool!("safe-compact-evidence", "small")
    secret = "ghp_" <> String.duplicate("a", 28)

    activity!(work, 2, "tool.completed", %{
      "kind" => "read",
      "title" => "Read file",
      "status" => "failed",
      "locations" => [%{"path" => "/workspace/" <> secret}],
      "error" => "Failed with " <> secret <> " " <> String.duplicate("x", 8_000)
    })

    activity!(work, 3, "tool.completed", %{
      "kind" => "read",
      "title" => "Read file",
      "status" => "completed",
      "locations" => [%{"path" => "/private/withheld-file"}],
      "withheld" => %{"locations" => "likely credential"}
    })

    document = work |> rendered() |> LazyHTML.from_document()
    text = LazyHTML.text(document)
    refute text =~ secret
    refute text =~ "/private/withheld-file"
    assert text =~ "[redacted]"
    assert text =~ "withheld"
    row = LazyHTML.query(document, "#event-activity-#{event_id(work, 2)} .tool-run-error")
    assert String.length(LazyHTML.text(row)) <= 400
    assert Enum.empty?(LazyHTML.query(document, ".tool-run-detail[open]"))
  end

  test "closed failures keep the human explanation rather than model-only state-tool codes" do
    # Native alert review found a bare invalid_arguments and model-only search
    # recovery instructions replacing the existing human explanation.
    work = episode_with_tool!("human-errors", "small")

    for {{error, expected}, sequence} <-
          Enum.with_index(
            [
              {"invalid_arguments",
               "Ryker rejected the call because its arguments did not match what the tool accepts."},
              {"search_unavailable: Do not retry.",
               "Slack lets Ryker search only for a short time after a message that mentions it, and this run had no such permission."}
            ],
            2
          ) do
      activity!(work, sequence, "tool.completed", %{
        "status" => "failed",
        "input" => %{"server" => "controller-tools", "tool" => "search_slack"},
        # The explanation is attached by the state-call join, not inferred
        # from an arbitrary worker tool's similarly named error code.
        "ryker_summary" => expected,
        "error" => error
      })

      document = work |> rendered() |> LazyHTML.from_document()
      row = LazyHTML.query(document, "#event-activity-#{event_id(work, sequence)}")
      assert Enum.empty?(LazyHTML.query(row, ".tool-run-detail[open]"))
      assert LazyHTML.query(row, ".tool-run-error") |> LazyHTML.text() == expected
    end
  end

  test "external failures do not inherit Ryker or Slack explanations from matching error codes" do
    # The first humanization pass mapped every provider's invalid_arguments
    # and search_unavailable to Ryker/Slack, even without host call evidence.
    work = episode_with_tool!("external-errors", "small")

    for {error, sequence} <- Enum.with_index(["invalid_arguments", "search_unavailable"], 2) do
      activity!(work, sequence, "tool.completed", %{
        "status" => "failed",
        "input" => %{"server" => "external-search", "tool" => "search"},
        "error" => error
      })

      document = work |> rendered() |> LazyHTML.from_document()
      row = LazyHTML.query(document, "#event-activity-#{event_id(work, sequence)}")
      assert LazyHTML.query(row, ".tool-run-error") |> LazyHTML.text() == error
    end
  end

  test "a completion withholding locations does not resurrect a start's path on the closed row" do
    work = episode_with_tool!("withheld-start-location", "small")

    activity!(work, 2, "tool.started", %{
      "tool_call_id" => "read-one",
      "kind" => "read",
      "title" => "Read file",
      "locations" => [%{"path" => "/private/withheld-file"}]
    })

    activity!(work, 3, "tool.completed", %{
      "tool_call_id" => "read-one",
      "kind" => "read",
      "status" => "completed",
      "withheld" => %{"locations" => "likely credential"}
    })

    document = work |> rendered() |> LazyHTML.from_document()
    summary = LazyHTML.query(document, "#event-activity-#{event_id(work, 3)} .tool-run-line")
    refute LazyHTML.text(summary) =~ "/private/withheld-file"
    assert LazyHTML.text(summary) =~ "withheld"
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
    assert Enum.any?(links, fn {id, _href} -> String.starts_with?(id, "steps-event-activity-") end)

    assert Enum.count(LazyHTML.query(document, ".tool-run-step[id^='event-activity-']")) == 1
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

    tool!(work, 3, "run_action", %{
      "action_id" => "cloud-init.log_tail",
      "args" => %{"lines" => 35},
      "pack_ref" => "cloud-init@0.1.19/sha256:" <> String.duplicate("c", 64),
      "reason" => "Inspect the completed initialization.",
      "runner_refs" => ["emisar-3hgr~" <> String.duplicate("1", 32)]
    })

    tool!(work, 4, "get_work_state", %{})
    tool!(work, 5, "list_packs", %{}, "failed")

    document = LazyHTML.from_document(rendered(work))
    [run] = document |> LazyHTML.query(".case-tool_run") |> Enum.to_list()

    assert LazyHTML.query(run, ".tool-run > .case-card-heading h3") |> LazyHTML.text() ==
             "Tool activity"

    assert LazyHTML.query(run, ".case-card-heading-detail") |> LazyHTML.text() == "5 steps"

    lines =
      run
      |> LazyHTML.query(".tool-run-step")
      |> Enum.map(fn step ->
        {LazyHTML.query(step, ".tool-run-line > .tool-run-badge > span")
         |> LazyHTML.text()
         |> String.trim(), LazyHTML.query(step, ".tool-run-title") |> LazyHTML.text(),
         LazyHTML.query(step, ".tool-run-text") |> LazyHTML.text()}
      end)

    assert lines == [
             {"Code", "Run command", "rg --files"},
             {"Emisar", "Emisar actions looked up", "gcp compute instances list"},
             # Which action ran where; why is the opened card's (2026-09-28).
             {"Emisar", "Emisar run requested", "cloud-init.log_tail · emisar-3hgr"},
             {"Ryker", "Work state read", ""},
             {"Emisar", "List Emisar packs", ""}
           ]

    assert LazyHTML.query(run, ".tool-run-badge[data-service=emisar] svg.emisar-mark")
           |> Enum.count() == 3

    # Ryker's own calls carry Ryker's mark, as Emisar's carry Emisar's.
    assert LazyHTML.query(
             run,
             ".tool-run-badge[data-service=ryker] img[src='/assets/brand/mark-mint.svg']"
           )
           |> Enum.count() == 1

    # The full card names the pack without the digest it was pinned by; the
    # raw arguments keep it, as they keep everything exactly.
    facts = run |> LazyHTML.query(".action-facts") |> LazyHTML.text()
    assert facts =~ "cloud-init@0.1.19"
    refute facts =~ "sha256"

    # An Emisar run's card names where it ran, the action's own arguments and
    # why, each under its name (Andrew, 2026-09-28).
    labels =
      run
      |> LazyHTML.query(".action-facts dt")
      |> Enum.map(&LazyHTML.text/1)

    assert labels == ["Action", "Pack", "Runner", "Lines", "Reason"]
    assert facts =~ "emisar-3hgr"
    refute facts =~ "~111"
    assert facts =~ "Inspect the completed initialization."

    # Each step keeps its own anchor and opens to its full card.
    assert run
           |> LazyHTML.query("li.tool-run-step")
           |> LazyHTML.attribute("id")
           |> Enum.all?(&String.starts_with?(&1, "event-activity-"))

    assert LazyHTML.query(run, "details.tool-run-detail .tool-run-body .action-card")
           |> Enum.count() == 5

    # Failure keeps the same closed row; its reason belongs on the summary.
    assert Enum.empty?(LazyHTML.query(run, ".tool-run-detail[open]"))

    assert LazyHTML.query(run, ".tool-run-detail .tool-run-duration") |> LazyHTML.text() =~
             "Failed"
  end

  # Andrew, 2026-09-28: "Run command — The worker reported that a command ran,
  # not which one" on every shell step; "workers must report commands,
  # thinking and everything else". The payloads below have the shape the live
  # worker's Codex sessions record once Coop narrates them.
  test "a narrated command shows what it ran and printed, and a thought shows what the model was thinking" do
    work = episode_with_tool!("narrated", "small")

    activity!(work, 2, "tool.completed", %{
      "kind" => "execute",
      "tool_call_id" => "exec-1",
      "status" => "completed",
      "title" => "Run git status",
      "input" => %{"command" => "git status --short", "cwd" => "/workspace"},
      "output" => %{"formatted_output" => " M lib/deploy.ex\n", "exit_code" => 1},
      "content" => [%{"type" => "terminal", "terminalId" => "t-1"}]
    })

    activity!(work, 3, "tool.completed", %{
      "kind" => "execute",
      "tool_call_id" => "exec-2",
      "status" => "completed",
      "title" => "Run curl",
      "withheld" => %{"input" => "likely GitHub token"}
    })

    activity!(work, 4, "model.thought", %{
      "text" =>
        "**Checking the deploy script**\n\nThe readiness probe starts before the migration.",
      "truncated" => false
    })

    document = LazyHTML.from_document(rendered(work, ["activity-#{event_id(work, 2)}-output"]))
    text = LazyHTML.text(document)

    assert LazyHTML.query(document, "pre.action-command-line") |> LazyHTML.text() =~
             "git status --short"

    assert text =~ "Exit code"
    assert text =~ "M lib/deploy.ex"
    assert text =~ "The command was withheld: it looked like it held a GitHub token."
    refute text =~ "The worker reported that a command ran, not which one."
    # The terminal the worker ran it in says nothing to a reader.
    refute text =~ "terminalId"

    assert text =~ "Checking the deploy script"
    assert text =~ "The readiness probe starts before the migration."
    refute text =~ "**Checking"

    # Andrew, 2026-10-01, of a card titled only "Selecting the reply button": "what does this card
    # mean in simple english, in practice?" It is the model's own note on what it was doing, and
    # it reads as one: a quiet line, not a card.
    assert [note] =
             document
             |> LazyHTML.query("article.case-entry")
             |> Enum.filter(&(LazyHTML.text(&1) =~ "Checking the deploy script"))

    assert LazyHTML.query(note, ".ui-activity-note-label") |> LazyHTML.text() == "Model's note"

    assert LazyHTML.query(note, ".ui-activity-note h3") |> LazyHTML.text() ==
             "Checking the deploy script"
  end

  test "every worker update uses the shared compact note without losing its evidence or warning" do
    # Provider heartbeats were still full-size cards and model notes had their
    # own page-local skin. A new activity kind must not silently restore either.
    work = episode_with_tool!("activity-notes", "small")

    events = [
      {"model.thought",
       %{"text" => "**Checking the deploy script**\n\nRead the migration first."}},
      {"model.thought", %{"text" => "A note without a separate heading."}},
      {"model.thought", %{"withheld" => %{"text" => "likely GitHub token"}}},
      {"model.progress", %{"text" => "Checking the running revision."}},
      {"provider.alive", %{"frames" => 1, "bytes" => 12_575}},
      {"provider.alive", %{}},
      {"provider.backoff", %{"target" => "codex", "retry_after_seconds" => 12}},
      {"model.plan",
       %{"step_count" => 1, "entries" => [%{"text" => "Read the migration first."}]}},
      {"permission.decided", %{"outcome" => "cancelled", "tool_call_id" => "permission-1"}},
      {"activity.elided", %{"dropped" => 12}},
      {"custom.notice", %{}}
    ]

    for {{kind, payload}, sequence} <- Enum.with_index(events, 2) do
      activity!(work, sequence, kind, payload)
    end

    document = LazyHTML.from_document(rendered(work))

    for sequence <- 2..12 do
      entry = LazyHTML.query(document, "#event-activity-#{event_id(work, sequence)}")
      assert Enum.count(LazyHTML.query(entry, ".ui-activity-note")) == 1
      assert Enum.empty?(LazyHTML.query(entry, ".case-card-heading"))
      assert Enum.empty?(LazyHTML.query(entry, ".case-event-content"))
    end

    heartbeat = LazyHTML.query(document, "#event-activity-#{event_id(work, 6)}")
    assert Enum.empty?(LazyHTML.query(heartbeat, "h3"))
    assert Enum.empty?(LazyHTML.query(heartbeat, ".ui-activity-note-text"))
    diagnostics = LazyHTML.query(heartbeat, "details")
    assert LazyHTML.attribute(diagnostics, "open") == []

    assert LazyHTML.query(diagnostics, ".ui-disclosure-label") |> LazyHTML.text() ==
             "Provider activity received"

    assert LazyHTML.text(diagnostics) =~ "12575"
    assert LazyHTML.text(diagnostics) =~ "Frames"
    assert LazyHTML.query(diagnostics, "dd") |> LazyHTML.text() =~ "1"

    empty = LazyHTML.query(document, "#event-activity-#{event_id(work, 7)}")
    assert Enum.empty?(LazyHTML.query(empty, ".ui-activity-note-text"))
    # The evidence protocol version is still retained, even without counters.
    assert LazyHTML.text(LazyHTML.query(empty, "details")) =~ "Evidence version"

    backoff = LazyHTML.query(document, "#event-activity-#{event_id(work, 8)}")
    assert Enum.count(LazyHTML.query(backoff, ".ui-activity-note[data-tone=warn]")) == 1

    assert LazyHTML.query(backoff, ".ui-activity-note-text") |> LazyHTML.text() =~
             "retrying in 12s"

    withheld = LazyHTML.query(document, "#event-activity-#{event_id(work, 4)}")

    assert LazyHTML.query(withheld, ".ui-activity-note-text") |> LazyHTML.text() =~
             "The worker withheld this thought: it looked like it held a GitHub token."

    assert LazyHTML.query(document, ".ui-activity-note h3") |> LazyHTML.text() =~
             "Model plan updated"

    plan_id = "activity-#{event_id(work, 9)}-plan"
    plan = LazyHTML.query(document, "#event-activity-#{event_id(work, 9)}")

    assert LazyHTML.attribute(LazyHTML.query(plan, "[data-artifact]"), "data-artifact") == [
             plan_id
           ]

    opened = LazyHTML.from_document(rendered(work, [plan_id]))

    assert LazyHTML.query(opened, "#event-activity-#{event_id(work, 9)} pre") |> LazyHTML.text() =~
             "Read the migration first."

    assert LazyHTML.text(document) =~ "Coop policy refused this unattended permission request."
    refute LazyHTML.text(document) =~ "1 frames"
  end

  defp activity!(work, sequence, kind, payload) do
    payload = Map.put(payload, "evidence_version", 1)

    Repo.insert!(%ActivityEvent{
      coop_turn_id: "coop-turn-run",
      episode_id: work.episode.id,
      kind: kind,
      occurred_at: DateTime.add(@now, 90 + sequence, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "narrated-event:#{sequence}",
      remote_session_id: "remote-session:#{work.session.id}",
      sequence: sequence,
      session_id: work.session.id,
      version: 1
    })
  end

  defp event_id(work, sequence) do
    Repo.one!(
      from(event in ActivityEvent,
        where: event.session_id == ^work.session.id and event.sequence == ^sequence,
        select: event.id
      )
    )
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

    {:ok, session} = WorkSessions.pin_episode(episode_id, "loading", String.duplicate("a", 64))
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
