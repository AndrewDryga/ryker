defmodule Ryker.ControlPlane.AdmittedMessagesTest do
  @moduledoc """
  Andrew, 2026-09-29, of PR #2's task timeline: five "Message added — Message
  added to this request." cards, one for the task and one for each comment
  and review on its pull request, and three "Handed to a new run": "maybe
  show those added messages? otherwise it's not clear what is happening
  during task setup at all". None of these inputs has an inbox row, so the
  page had nothing to show for them but the kernel's word. The fixture is that
  task's own admitted inputs, pruned to the fields the page reads.
  """
  use Ryker.DataCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.ControlPlane.EpisodeTrace.Input
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, Session}

  @fixture "testdata/control_plane/admitted-task-and-pr-feedback.json"

  test "a task's request and the comments and reviews on its pull request read as the messages they are" do
    key = admit_all!()
    {:ok, detail} = EpisodeProjection.fetch(key)

    refute Enum.any?(detail.trace.steps, &(&1.title == "Message added"))

    assert Enum.map(detail.trace.case_file.conversation, &{&1.title, &1.actor, &1.text}) == [
             {"Task approved", "Slack user",
              "**README workflow smoke test**\n\n" <> task_prompt()},
             {"Comment on PR #2", "AndrewDryga", "Ryker can you bring this up to date?"},
             {"Comment on PR #2", "AndrewDryga", "@ryker-bot hi"},
             {"Review of PR #2", "AndrewDryga", "Left a review with comments on the change."},
             {"Comment on README.md in PR #2", "AndrewDryga", "Add one more line please"}
           ]

    assert Enum.map(tl(detail.trace.case_file.conversation), & &1.source.href) == [
             "https://github.com/AndrewDryga/test/pull/2#issuecomment-5877326123",
             "https://github.com/AndrewDryga/test/pull/2#issuecomment-5877331728",
             "https://github.com/AndrewDryga/test/pull/2#pullrequestreview-5343845866",
             "https://github.com/AndrewDryga/test/pull/2#discussion_r4126405033"
           ]

    document = key |> rendered() |> LazyHTML.from_document()

    # The task's request opens the task; each comment and review on its pull
    # request is a message of its own, with the link to where it was written.
    assert LazyHTML.query(document, ".timeline-index a") |> Enum.map(&LazyHTML.text/1) ==
             ["Before the first message", "Message 1", "Message 2", "Message 3", "Message 4"]

    text = LazyHTML.text(document)
    assert text =~ "Task approved"
    assert text =~ "Ryker can you bring this up to date?"
    assert text =~ "Add one more line please"
    refute text =~ "Message added to this request."

    assert LazyHTML.query(
             document,
             ~s(.message-source a[href^="https://github.com/AndrewDryga/test/pull/2#"])
           )
           |> Enum.count() == 4
  end

  # Andrew, 2026-09-29, of this task's page: its two sessions' cleanups, at
  # 13:13 on 27 Sep and 22:37 on 28 Sep, sat in one Cleanup section after all
  # its messages: "we should not show cleanup as one section showing all
  # cleanups but show such section/divider in a timeline, so it doesn't show 2
  # here but shows when they actually occured (same for learning)".
  test "each cleanup is a section of its own, placed among the messages when it happened" do
    key = admit_all!()
    episode = Repo.get_by!(Episode, key: key)

    assert {:ok, first} =
             Custody.pin_episode(episode.id, "work", String.duplicate("a", 64))

    first =
      first
      |> Ecto.Changeset.change(
        coop_session_id: "remote-first",
        cleanup_status: :discarded,
        closed_at: ~U[2026-09-27 13:11:25.000000Z],
        discarded_at: ~U[2026-09-27 13:13:57.000000Z],
        cleanup_receipt: %{"kind" => "discarded", "remote_state" => "discarded"},
        cleanup_receipt_fingerprint: String.duplicate("c", 64),
        discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => false}},
        discard_plan_fingerprint: String.duplicate("d", 64),
        discard_plan_operation_id: "plan:first"
      )
      |> Repo.update!()

    %Session{first | id: Ecto.UUID.generate(), generation: 2}
    |> Ecto.put_meta(state: :built)
    |> Ecto.Changeset.change(
      coop_session_id: "remote-second",
      cleanup_status: :retained,
      closed_at: ~U[2026-09-28 22:36:52.000000Z],
      discarded_at: nil,
      cleanup_receipt: nil,
      cleanup_receipt_fingerprint: nil,
      discard_plan: nil,
      discard_plan_fingerprint: nil,
      discard_plan_operation_id: nil,
      retained_reason: "dirty_worktree"
    )
    |> Repo.insert!()

    document = key |> rendered() |> LazyHTML.from_document()

    assert LazyHTML.query(document, ".timeline-index a") |> Enum.map(&LazyHTML.text/1) == [
             "Before the first message",
             "Cleanup",
             "Message 1",
             "Message 2",
             "Message 3",
             "Message 4",
             "Cleanup"
           ]

    sections = LazyHTML.query(document, "section.background-chapter")
    assert Enum.count(sections) == 2

    assert Enum.map(
             sections,
             &(&1 |> LazyHTML.query(".phase-number") |> LazyHTML.text() |> String.trim())
           ) ==
             ["B1", "B2"]

    [removed, kept] = Enum.map(sections, &LazyHTML.text/1)
    assert removed =~ "Working copy removed"
    refute removed =~ "Working copy kept"
    assert kept =~ "Working copy kept"
  end

  # "(same for learning)": a learning pass's attempts share their batch and
  # stay one section; another pass is another section, where it ran.
  test "each learning pass is a section of its own, placed among the messages when it ran" do
    chapters = [
      conversation(0, ~U[2026-09-28 10:00:00Z]),
      learning("batch-1", "run-1", ~U[2026-09-28 10:30:00Z]),
      learning("batch-1", "run-2", ~U[2026-09-28 10:40:00Z]),
      conversation(1, ~U[2026-09-28 11:00:00Z]),
      learning("batch-2", "run-3", ~U[2026-09-28 12:00:00Z])
    ]

    groups = EpisodePage.timeline_groups(chapters)

    assert Enum.map(groups, &{&1.marker, &1.title}) == [
             {"—", "Before the first message"},
             {"B1", "Learning"},
             {"M1", "Message 1"},
             {"B2", "Learning"}
           ]

    # Both attempts of the first pass, with their results, in its one section.
    assert groups
           |> Enum.at(1)
           |> Map.fetch!(:phases)
           |> Enum.flat_map(& &1.steps)
           |> Enum.map(& &1.id) ==
             [
               "learning-run-1",
               "learning-run-1-result",
               "learning-run-2",
               "learning-run-2-result"
             ]
  end

  defp conversation(turn, at) do
    chapter(:ready, turn, [%{id: "message-#{turn}", kind: :message, band: :ready, at: at}])
  end

  defp learning(batch, run, at) do
    steps =
      for {suffix, offset} <- [{"", 0}, {"-result", 60}],
          do: %{
            id: "learning-#{run}#{suffix}",
            kind: :request,
            band: :learning,
            occurrence: batch,
            at: DateTime.add(at, offset, :second)
          }

    chapter(:learning, nil, steps)
  end

  defp chapter(band, turn, steps),
    do: %{
      band: band,
      conversation_turn: turn,
      owners: [:episode],
      starts_conversation: turn not in [nil, 0],
      steps: steps,
      title: nil,
      turn: nil
    }

  # The same task's three "Handed to a new run" were retries of a stopped run
  # (22:01, 22:08 and 22:16 UTC on 2026-09-28); the card said only that a run
  # started again.
  test "a run started again by a retry says so" do
    event = %Event{
      kind: :owner_transferred,
      sequence: 8,
      dedupe_key:
        "transfer_owner:42d730b5909180e6f2873f7b3d032c1ab882aa90aab7217f52b9cd5de76518cb",
      occurred_at: ~U[2026-09-28 22:01:19.400170Z],
      payload: %{
        "kind" => "transfer_owner",
        "expected_owner" => %{
          "kind" => "turn",
          "ref" => "turn:publication-feedback:e93007db-6966-46ce-c7d3-944402425286"
        },
        "new_owner" => %{
          "kind" => "turn",
          "ref" => "turn:resume-blocked:ae7ef6ee-6a82-4eae-ab17-2cdbac73ecff:v6"
        },
        "transfer_ref" => "transfer:resume-blocked:ae7ef6ee-6a82-4eae-ab17-2cdbac73ecff:v6"
      }
    }

    assert [%{title: "Handed to a new run", summary: summary}] =
             Input.kernel_steps([event], %{})

    assert summary == "The run had stopped, and a retry started it again as a new run."
  end

  # -- Fixture -------------------------------------------------------------------------

  defp events, do: @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("events")

  # What the person asked for, without the checks and references the host
  # appends for the Work, as the task card shows it.
  defp task_prompt do
    [request | _appended] =
      events()
      |> hd()
      |> get_in(["payload", "task", "prompt"])
      |> String.split("\n\nSuccess checks: ")

    String.trim(request)
  end

  defp admit_all! do
    id = Ecto.UUID.generate()
    key = "admitted-messages:#{id}"
    workspace = "TADMITTED#{System.unique_integer([:positive])}"

    for {event, index} <- Enum.with_index(events(), 1) do
      {:ok, occurred_at, 0} = DateTime.from_iso8601(event["occurred_at"])

      assert {:ok, _transition} =
               Episodes.apply(
                 EpisodeFixtures.admit_input(%{
                   actor_ref: event["actor_ref"],
                   destination: %{
                     conversation_ref: "slack:#{workspace}:C0BLU1GACKC",
                     thread_ref: event["destination"]["thread_ref"],
                     transport: "slack"
                   },
                   episode_id: id,
                   episode_key: key,
                   native_input_id: "admitted-messages:#{id}:#{index}",
                   occurred_at: occurred_at,
                   payload: event["payload"],
                   turn_ref: "turn:admitted-messages:#{id}:#{index}"
                 })
               )
    end

    key
  end

  defp rendered(key) do
    {:ok, detail} = EpisodeProjection.fetch(key)
    {:ok, timeline} = ModelRequests.timeline(key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end
end
