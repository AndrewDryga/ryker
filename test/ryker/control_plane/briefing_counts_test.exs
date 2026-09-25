defmodule Ryker.ControlPlane.BriefingCountsTest do
  @moduledoc """
  Counted partial rows on the briefing cards.

  Projection keeps the exact counted selection facts for inspection. The prompt
  summary itself stays concise: message cards do not repeat selection counts,
  while candidate selection uses a compact supplied/eligible ratio and retains
  the reason for anything excluded.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection, RequestPage}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input
  alias Ryker.Work.{Custody, Submission}

  @now ~U[2026-09-04 22:51:44.000000Z]

  @ledger %{
    "version" => 1,
    "mode" => "full",
    "inputs" => %{
      "eligible" => 48,
      "current" => 2,
      "earlier_included" => 30,
      "omitted_window" => 8,
      "omitted_fit" => 8
    },
    "limits" => %{"max_inputs" => 40, "context_bytes" => 163_840}
  }

  test "what a Work turn left out is its own card, and the briefing counts only what was sent" do
    # The briefing is the record of what the model was sent. Eligible, outside
    # the window and cut to fit are Ryker's selection, made before the briefing,
    # so they are a card of their own rather than a count inside it.
    work = frozen!("ledger", @ledger)
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    ids = Enum.map(timeline.items, & &1.id)
    selection = Enum.find(timeline.items, &String.starts_with?(&1.id, "event-selection-"))
    briefing = Enum.find(timeline.items, &(&1[:source_kind] == :work and &1.phase == :submission))

    assert Enum.find_index(ids, &(&1 == selection.id)) <
             Enum.find_index(ids, &(&1 == briefing.id))

    card = selection.step.search
    assert card.summary == "3 of 48 messages sent"

    assert {"Messages",
            "2 current · 1 earlier sent · 8 outside the history window · 8 cut to fit"} in card.facts

    assert {"Limits", "Up to 40 messages · 160 KiB of context"} in card.facts

    # Sent is counted from the frozen request, the exact set that reached the
    # model; this ledger claims thirty earlier messages and the request has one.
    refute Enum.any?(card.facts, fn {_label, value} -> value =~ "30" end)

    html = rendered(work.episode)

    # Match the count, not the digits: the card shows its time, and any run at
    # a minute or second of 48 failed here.
    briefing_text =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("##{briefing.id}")
      |> LazyHTML.text()

    refute briefing_text =~ ~r/\b48 (earlier )?(messages|inputs)\b|\bof 48\b/
  end

  test "a turn without a selection ledger has no selection card" do
    work = frozen!("no-ledger", nil)
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    refute Enum.any?(timeline.items, &String.starts_with?(&1.id, "event-selection-"))
  end

  test "the briefing counts come from the frozen context" do
    work = frozen!("included-only", nil)
    assert counts(work.episode)["records"] == %{label: "0 included", known?: true}
  end

  test "a continuation counts new messages and never calls earlier ones omitted" do
    work =
      frozen!(
        "continuation",
        %{
          "version" => 1,
          "mode" => "continuation",
          "inputs" => %{"current" => 1, "earlier_not_resent" => 4}
        },
        continuation: true
      )

    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    card = Enum.find(timeline.items, &String.starts_with?(&1.id, "event-selection-")).step.search
    assert card.summary == "Continues the session · 1 new message"
    assert {"Messages", "1 new · 4 earlier already in the session"} in card.facts
    refute Enum.any?(card.facts, fn {_label, value} -> value =~ "omitted" end)
  end

  test "the search for earlier work is its own card, before the briefing it fed" do
    # The search showed inside the briefing, which is the record of what the
    # model was sent. A timeline card is not edited to add another step's
    # facts: the search ran first, so it is a card of its own, first.
    {entry, episode} =
      admitted!(%{
        "routing_receipt" => %{
          "cutoff_reason" => "shortlist_limit",
          "eligible_conversations" => 3,
          "examined" => 5,
          "lanes" => %{
            "text" => %{"returned" => 5, "saturated" => false},
            "thread" => %{"returned" => 2, "saturated" => false}
          },
          "offered" => 2,
          "omitted" => 3,
          "scope" => "workspace_public"
        },
        "knowledge_omissions" => [%{"reason" => "source_capacity"}]
      })

    {:ok, view} = ModelRequests.project_input(entry.id, %{})
    ids = Enum.map(view.timeline, & &1.id)
    search = "event-search-#{entry.id}-1"

    assert Enum.find_index(ids, &(&1 == search)) <
             Enum.find_index(ids, &(&1 == "admission-#{entry.id}-1"))

    html = rendered(episode)
    card = html |> LazyHTML.from_document() |> LazyHTML.query("##{search}") |> LazyHTML.text()
    assert card =~ "Search for earlier work"
    assert card =~ "5 found, 2 offered"
    assert card =~ "Public channels Ryker is in: 3 conversations"
    assert card =~ "5 found, 2 offered to routing · 3 left out (shortlist limit)"
    assert card =~ "1 learned topic left out to fit"

    # Each of the four searches is its own line with what it found, even the
    # ones that found nothing; this older record kept no words.
    methods =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("##{search} .search-methods li")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert methods == [
             "Same thread 2 found",
             "Same links or IDs 0 found",
             "Similar wording 5 found",
             "Work still in progress 0 found"
           ]

    # The briefing keeps to what was sent: no search facts, no work left out.
    briefing =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#admission-#{entry.id}-1")
      |> LazyHTML.text()

    refute briefing =~ "How Ryker searched"
    refute briefing =~ "Not supplied"
    refute briefing =~ "left out"
  end

  test "a search says which words, links and places it used, and why a search did not run" do
    # Andrew, 2026-09-24: "can we show in a nicer way what was searched and
    # how? by keywords? where?" The card said "Looked in: This conversation
    # only" and nothing about what was looked for.
    {entry, episode} =
      admitted!(%{
        "routing_receipt" => %{
          "cutoff_reason" => "every eligible candidate was offered",
          "eligible_conversations" => 1,
          "examined" => 0,
          "lanes" => %{
            "identity" => %{"returned" => 0, "saturated" => false},
            "recent_active" => %{"returned" => 0, "saturated" => false},
            "text" => %{"returned" => 0, "saturated" => false},
            "thread" => %{"returned" => 0, "saturated" => false}
          },
          "offered" => 0,
          "omitted" => 0,
          "scope" => "conversation",
          "words" => ["kubernetes", "liveness", "readiness", "probe"],
          "identifiers" => [],
          "in_thread" => false,
          "history_since" => "2026-09-16T20:01:29Z",
          "conversation_refs" => ["control-plane:lab:one"]
        }
      })

    search = "event-search-#{entry.id}-1"
    document = episode |> rendered() |> LazyHTML.from_document() |> LazyHTML.query("##{search}")

    assert LazyHTML.text(document) =~
             "This conversation · work finished since 16 Sep, and all work still in progress"

    assert document |> LazyHTML.query(".search-method-used code") |> Enum.map(&LazyHTML.text/1) ==
             ["kubernetes", "liveness", "readiness", "probe"]

    notes = document |> LazyHTML.query(".search-method-note") |> Enum.map(&LazyHTML.text/1)
    assert notes == ["the message was not in a thread", "no links or IDs in the message"]

    assert LazyHTML.text(document) =~ "Nothing found, so routing had no earlier work to consider."
  end

  test "an attempt without its own search record has no search card" do
    {entry, _episode} = admitted!(nil)
    {:ok, view} = ModelRequests.project_input(entry.id, %{})
    refute Enum.any?(view.timeline, &String.starts_with?(&1.id, "event-search-"))
  end

  test "a routing candidate resolves to its own episode timeline" do
    # The candidate card used to load the earlier episode's messages the router
    # never read. It now links to that episode, resolved from the host-side
    # snapshot because the model only ever saw an opaque candidate ref.
    candidate_id = Ecto.UUID.generate()
    candidate_ref = "candidate:#{String.duplicate("c", 64)}"
    candidate_key = "candidate-history:#{candidate_id}"
    {input, history_entry} = recorded_history_input!(candidate_id, 1)

    {:ok, %{episode: candidate_episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: candidate_id,
          episode_key: candidate_key,
          native_input_id: input.native_input_id,
          occurred_at: input.occurred_at,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "candidate-history-turn:1:#{candidate_id}"
        })
      )

    associate_history_entry!(history_entry, candidate_episode.id)

    candidate = %{
      "allowed_relations" => ["same_work", "history_only"],
      "episode_ref" => candidate_ref,
      "evidence" => ["same thread"],
      "first_message" => %{
        "actor" => "U-history",
        "at" => DateTime.to_iso8601(input.occurred_at),
        "text" => "History message 1"
      },
      "idle_minutes" => 0,
      "message_count" => 1,
      "state" => "complete",
      "title" => "Investigate candidate history"
    }

    snapshot = %{
      "built_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "candidates" => [Map.put(candidate, "episode_id", candidate_episode.id)],
      "conversation_episode_count" => 1
    }

    {entry, _episode} = admitted!(snapshot, [candidate])
    href = "/timeline/" <> URI.encode_www_form(candidate_key)

    assert {:ok, view} = ModelRequests.project_input(entry.id, %{})
    assert view.selected.counts["candidate_episodes"] == %{candidate_ref => href}

    html =
      render_component(&RequestPage.render/1,
        view: view,
        params: %{},
        path: "/timeline/#{entry.id}"
      )

    document = LazyHTML.from_document(html)

    assert document
           |> LazyHTML.query(".context-candidate a.candidate-episode-link")
           |> LazyHTML.attribute("href") == [href]

    refute html =~ "not sent to the model"
  end

  defp counts(episode) do
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    Enum.find_value(timeline.items, %{}, &(&1[:source_kind] == :work && &1[:counts]))
  end

  defp admission_counts(episode, entry) do
    {:ok, view} = ModelRequests.project_input(entry.id, %{})
    _ = episode
    view.selected.counts
  end

  defp rendered(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp frozen!(suffix, ledger, options \\ []) do
    episode_id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "briefing-counts:#{suffix}:#{episode_id}",
          native_input_id: "source:#{suffix}:#{episode_id}",
          turn_ref: "turn:#{suffix}:#{episode_id}"
        })
      )

    {:ok, _session} = Custody.pin_episode(episode_id, "counts", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("counts:#{suffix}", 120, :work)

    context =
      if Keyword.get(options, :continuation) do
        %{
          "mode" => "continuation",
          "current_inputs" => %{"items" => [%{"current" => true}], "omitted_count" => 0}
        }
      else
        %{
          "mode" => "full",
          "inputs" => %{
            "items" => [
              %{"current" => true},
              %{"current" => true},
              %{"current" => false}
            ],
            "omitted_count" => 16
          },
          "records" => []
        }
      end

    {:ok, submission} =
      Submission.new(
        %{"work" => context},
        prompt(context),
        %{"type" => "object"},
        "work-final-live-v3"
      )

    {:ok, turn} =
      Custody.freeze_submission(episode_id, claim.turn.turn_ref, claim.lease_ref, submission,
        selection_ledger: ledger
      )

    %{episode: claim.episode, turn: turn}
  end

  # The timeline reads the context out of the retained prompt document, so the
  # fixture writes exactly the document the builder writes.
  defp prompt(context), do: Jason.encode!(%{"instructions" => "Investigate", "work" => context})

  defp admitted!(snapshot, candidates \\ [%{"state" => "active"}, %{"state" => "complete"}]) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Check the alert"},
        event_kind: :message,
        event_ref: "Ev-counts-#{Ecto.UUID.generate()}",
        message_ref: "#{1_788_562_304 + System.unique_integer([:positive])}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: entry.id,
          episode_key: "ingress-input:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @now,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    submission = %{
      "prompt" =>
        Jason.encode!(%{
          "instructions" => "Classify",
          "context" => %{"candidates" => candidates}
        }),
      "output_schema" => %{"type" => "object"}
    }

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: 1,
      policy: "admission",
      policy_digest: String.duplicate("b", 64),
      submission: submission,
      submission_fingerprint: CanonicalJSON.digest(submission),
      phase: "response_received"
    })

    decision = %{"action" => "reply", "reason" => "A direct reply."}

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        admission_context: snapshot,
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        status: :decided
      ]
    )

    {Repo.get!(Entry, entry.id), episode}
  end

  defp recorded_history_input!(candidate_id, index, options \\ []) do
    text = Keyword.get(options, :text, "History message #{index}")
    occurred_at = Keyword.get(options, :occurred_at, DateTime.add(@now, index, :second))

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U-history"},
        channel_ref: "C-history",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-history-#{candidate_id}-#{index}",
        message_ref: "1788562304.#{String.pad_leading(to_string(index), 6, "0")}",
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: "1788562304.000001",
        workspace_ref: "T-history"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    {input, entry}
  end

  defp associate_history_entry!(entry, episode_id) do
    decision = %{"action" => "continue_episode", "reason" => "Related history fixture."}

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :continue_episode,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode_id,
        status: :decided
      ]
    )

    Repo.get!(Entry, entry.id)
  end
end
