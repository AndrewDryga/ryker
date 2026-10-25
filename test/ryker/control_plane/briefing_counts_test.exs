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
  alias Ryker.ControlPlane.{EpisodePage, EpisodeProjection, ModelRequests}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input
  alias Ryker.Work.{Custody, Session, Submission, Turn}

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

  # Andrew, 2026-10-16: a Work run read as two cards, a Context selection card
  # saying in a sentence which messages the model was given, then the Work
  # briefing with only the new ones. The briefing now shows its messages as
  # routing's does, and what the selection left out sits beside the row it
  # cut; the ledger itself is under the briefing's Details.
  test "what a new session left out sits beside its earlier messages, with no card of its own" do
    work = frozen!("ledger", @ledger)
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    refute Enum.any?(timeline.items, &String.starts_with?(&1.id, "event-selection-"))

    briefing = Enum.find(timeline.items, &(&1[:source_kind] == :work and &1.phase == :submission))
    document = work.episode |> rendered() |> LazyHTML.from_document()
    card = LazyHTML.query(document, "##{briefing.id}")

    assert rows(card) == [
             "New messages · 2 messages",
             "Earlier in this request · 1 message · 16 left out"
           ]

    assert words(text(card, ".prompt-source[data-source=earlier_in_request]")) =~
             "16 earlier messages were left out: 8 beyond the 40 most recent and 8 to fit " <>
               "the size limit."

    # Sent is counted from the frozen request, the exact set that reached the
    # model; this ledger claims thirty earlier messages and the request has one,
    # and the 48 it says existed is no count of what was sent.
    refute text(card, ".prompt-assembly") =~ "30"
    refute text(card, ".prompt-assembly") =~ ~r/\b48 (earlier )?(messages|inputs)\b|\bof 48\b/

    details = LazyHTML.query(card, "details.request-selection")
    assert LazyHTML.attribute(details, "open") == []
    assert words(text(details, ".ui-facts")) == "Limits Up to 40 messages · 160 KiB of context"

    record = Jason.encode!(@ledger, pretty: true)
    selection = LazyHTML.query(details, "details.json-disclosure")
    assert text(selection, ".ui-disclosure-label") == "Selection record"
    assert text(selection, ".ui-disclosure-meta") == "JSON · #{byte_size(record)} bytes"
    assert text(selection, "pre") == record
  end

  test "a turn without a selection ledger has no Details and no selection card" do
    work = frozen!("no-ledger", nil)
    {:ok, timeline} = ModelRequests.timeline(work.episode.key, %{})
    refute Enum.any?(timeline.items, &String.starts_with?(&1.id, "event-selection-"))
    refute Enum.any?(timeline.items, &(&1[:selection] != nil))

    document = work.episode |> rendered() |> LazyHTML.from_document()
    assert Enum.empty?(LazyHTML.query(document, ".request-selection"))
  end

  test "the briefing counts come from the frozen context" do
    work = frozen!("included-only", nil)
    assert counts(work.episode)["records"] == %{label: "0 included", known?: true}
  end

  test "a kind of saved context the ledger cut says how many of how many were sent" do
    ledger =
      Map.merge(@ledger, %{
        "observations" => %{"included" => 1, "eligible" => 3},
        "records" => %{"included" => 0, "eligible" => 2},
        "memory" => %{"included" => 0, "eligible" => 0}
      })

    work =
      frozen!("listed", ledger,
        operator_context: %{"continuity" => %{"observations" => [%{"text" => "A note"}]}}
      )

    counts = counts(work.episode)
    assert counts["continuity"].label == "1 of 3 source notes"
    assert counts["records"].label == "0 of 2 included"
    refute Map.has_key?(counts, "memory")
  end

  # The continuation's Work briefing showed only its new message; the Context
  # selection card before it said the session "already has the 5 earlier
  # messages", which nobody could open. Those messages are read from the
  # frozen records of the session's earlier runs.
  test "a continued session lists the earlier messages it already holds, never as left out" do
    first = frozen!("chain", nil, items: [message("A", false), message("B", true)])
    second = continued!(first, [message("C", true)], first.turn.submission_fingerprint)
    third = continued!(first, [message("D", true)], second.submission_fingerprint)

    document = first.episode |> rendered() |> LazyHTML.from_document()

    assert rows(LazyHTML.query(document, "#request-#{third.id}")) == [
             "New messages",
             "Earlier in this request · 3 messages · already in saved conversation context"
           ]

    assert message_texts(document, third) == ["A", "B", "C"]
    assert message_texts(document, second) == ["A", "B"]

    assert Enum.empty?(
             LazyHTML.query(
               document,
               "#request-#{third.id} [data-source=earlier_in_request] [data-prompt-highlight]"
             )
           )

    earlier =
      text(document, "#request-#{third.id} .prompt-source[data-source=earlier_in_request]")

    assert words(earlier) =~ "Earlier messages remain available; this call adds the new message."
    refute earlier =~ "left out"

    # Earlier messages are held, not sent: the row has no token estimate.
    assert document
           |> LazyHTML.query(
             "#request-#{third.id} .prompt-source[data-source=earlier_in_request] .prompt-source-estimate"
           )
           |> Enum.empty?()
  end

  test "a run retention removed ends the chain, and the row says only some are still kept" do
    first = frozen!("pruned", nil, items: [message("A", true)])
    second = continued!(first, [message("B", true)], first.turn.submission_fingerprint)
    third = continued!(first, [message("C", true)], second.submission_fingerprint)

    Repo.update_all(from(turn in Turn, where: turn.id == ^first.turn.id),
      set: [submission: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    document = first.episode |> rendered() |> LazyHTML.from_document()

    assert rows(LazyHTML.query(document, "#request-#{third.id}")) == [
             "New messages",
             "Earlier in this request · 1 message still kept · already in saved conversation context"
           ]

    assert message_texts(document, third) == ["B"]

    gone =
      LazyHTML.query(
        document,
        "#request-#{second.id} .prompt-source[data-source=earlier_in_request]"
      )

    assert text(gone, ".prompt-source-title") == "Earlier in this request"
    assert text(gone, ".prompt-source-status") == "No longer kept"
  end

  # A turn's parent is named by fingerprint. One that matches a run of
  # another session, or of another request, is never read as this one's.
  test "a parent from another session or request is never read as saved context" do
    other = frozen!("elsewhere", nil, items: [message("Other request", true)])
    first = frozen!("own", nil, items: [message("A", true)])

    other_session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: first.episode.id,
        generation: 2,
        policy: "counts",
        policy_digest: String.duplicate("a", 64),
        external_ref: "replacement:#{first.turn.session_id}"
      })

    stray =
      continued!(first, [message("B", true)], other.turn.submission_fingerprint)

    elsewhere =
      continued!(first, [message("C", true)], first.turn.submission_fingerprint,
        session_id: other_session.id
      )

    document = first.episode |> rendered() |> LazyHTML.from_document()

    for turn <- [stray, elsewhere] do
      assert rows(LazyHTML.query(document, "#request-#{turn.id}")) == ["New messages"]
    end

    refute LazyHTML.text(document) =~ "Other request"
  end

  test "a request's first message has its new message alone, with no counter and no limits" do
    # Andrew, 2026-09-26: the card's header said "1 of 1 message sent" and
    # listed limits that cut nothing.
    work =
      frozen!(
        "first",
        %{
          "version" => 1,
          "mode" => "full",
          "inputs" => %{
            "eligible" => 1,
            "current" => 1,
            "earlier_included" => 0,
            "omitted_window" => 0,
            "omitted_fit" => 0
          },
          "limits" => %{"max_inputs" => 40, "context_bytes" => 163_840}
        },
        items: [%{"current" => true}],
        omitted: 0
      )

    card =
      work.episode
      |> rendered()
      |> LazyHTML.from_document()
      |> LazyHTML.query(".episode-request:has(.request-selection)")

    assert rows(card) == ["New messages"]
    refute LazyHTML.text(card) =~ "1 of 1"
    refute text(card, ".prompt-assembly") =~ "left out"
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
    assert html =~ ~s(class="ui-disclosure ui-disclosure-source search-method")
    card = html |> LazyHTML.from_document() |> LazyHTML.query("##{search}") |> LazyHTML.text()
    assert card =~ "Context search"
    assert card =~ "5 found, 2 offered"
    assert card =~ "Public channels Ryker is in: 3 conversations"

    assert card =~
             "5 found, 2 offered to routing as Related history · 3 left out (shortlist limit)"

    assert card =~ "1 learned topic left out to fit"

    # Each of the four searches is its own line with what it found, even the
    # ones that found nothing; this older record kept no words.
    methods =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("##{search} .search-methods li summary .ui-disclosure-label")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert methods == [
             "Same thread · 2 found",
             "Same links or IDs · 0 found",
             "Similar wording · 5 found",
             "Work still in progress · 0 found"
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

    assert document |> LazyHTML.query(".search-query code") |> Enum.map(&LazyHTML.text/1) ==
             ["kubernetes", "liveness", "readiness", "probe"]

    assert document |> LazyHTML.query(".search-method-used code") |> Enum.map(&LazyHTML.text/1) ==
             ["kubernetes", "liveness"]

    assert document |> LazyHTML.query(".search-method-used") |> LazyHTML.text() =~ "+2 more"

    notes = document |> LazyHTML.query(".search-method-note") |> Enum.map(&LazyHTML.text/1)
    assert notes == ["the message was not in a thread", "no links or IDs in the message"]

    assert LazyHTML.text(document) =~ "Nothing found, so routing had no earlier work to consider."
  end

  # Andrew, 2026-09-30, of a card whose wording chips read "run git log
  # oneline repository three latest commit subjects. read change nothing.":
  # "I think the way we search is rudimentary". The card now shows only the
  # words that tell work apart, says which were too common, and shows the
  # search by meaning, or why it did not run.
  test "a search shows the telling words, the common ones it left out, and its search by meaning" do
    lanes = %{
      "identity" => %{"returned" => 0, "saturated" => false},
      "meaning" => %{"returned" => 2, "saturated" => false},
      "recent_active" => %{"returned" => 0, "saturated" => false},
      "text" => %{"returned" => 1, "saturated" => false},
      "thread" => %{"returned" => 0, "saturated" => false}
    }

    receipt = %{
      "cutoff_reason" => "every eligible candidate was offered",
      "eligible_conversations" => 1,
      "examined" => 2,
      "lanes" => lanes,
      "offered" => 2,
      "omitted" => 0,
      "scope" => "conversation",
      "words" => ["oneline", "commit"],
      "common_words" => ["run", "change"],
      "identifiers" => [],
      "in_thread" => false,
      "meaning" => %{"model" => "bge-m3"},
      "history_since" => "2026-09-16T20:01:29Z",
      "conversation_refs" => ["control-plane:lab:one"]
    }

    {entry, episode} = admitted!(%{"routing_receipt" => receipt})
    search = "event-search-#{entry.id}-1"
    document = episode |> rendered() |> LazyHTML.from_document() |> LazyHTML.query("##{search}")

    methods =
      document
      |> LazyHTML.query(".search-methods li")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

    assert Enum.any?(methods, &String.starts_with?(&1, "Similar meaning"))

    assert document |> LazyHTML.query(".search-method-used code") |> Enum.map(&LazyHTML.text/1) ==
             ["oneline", "commit"]

    notes = document |> LazyHTML.query(".search-method-note") |> Enum.map(&LazyHTML.text/1)
    assert "left out as too common: run, change" in notes
    assert "compared by bge-m3 in any language" in notes

    stopped =
      put_in(receipt, ["meaning"], %{"unavailable" => "the embedding server could not be reached"})

    {entry, episode} = admitted!(%{"routing_receipt" => stopped})
    search = "event-search-#{entry.id}-1"
    document = episode |> rendered() |> LazyHTML.from_document() |> LazyHTML.query("##{search}")
    notes = document |> LazyHTML.query(".search-method-note") |> Enum.map(&LazyHTML.text/1)
    assert "the embedding server could not be reached, so this search did not run" in notes
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
    href = "/timeline/" <> candidate_id

    assert {:ok, view} = ModelRequests.project_input(entry.id, %{})
    briefing = Enum.find(view.timeline, &(&1.id == "admission-#{entry.id}-1"))
    assert briefing.counts["candidate_episodes"] == %{candidate_ref => href}

    html = render_component(&EpisodePage.message_page/1, view: view)
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

  defp rendered(episode) do
    {:ok, detail} = EpisodeProjection.fetch(episode.key)
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

    {:ok, _session} = WorkSessions.pin_episode(episode_id, "counts", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("counts:#{suffix}", 120, :work)

    context =
      if Keyword.get(options, :continuation) do
        %{
          "mode" => "continuation",
          "current_inputs" => %{"items" => [%{"current" => true}], "omitted_count" => 0}
        }
      else
        items =
          Keyword.get(options, :items, [
            %{"current" => true},
            %{"current" => true},
            %{"current" => false}
          ])

        %{
          "mode" => "full",
          "inputs" => %{"items" => items, "omitted_count" => Keyword.get(options, :omitted, 16)},
          "operator_context" => Keyword.get(options, :operator_context, %{}),
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

  # A later run of `first`'s request that continues a session: its new
  # messages and its parent's fingerprint, as the builder writes them.
  defp continued!(first, items, parent, options \\ []) do
    context = %{
      "mode" => "continuation",
      "parent_submission_ref" => parent,
      "current_inputs" => %{"items" => items, "omitted_count" => 0}
    }

    {:ok, submission} =
      Submission.new(
        %{"work" => context},
        prompt(context),
        %{"type" => "object"},
        "work-final-live-v3"
      )

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: first.episode.id,
      session_id: Keyword.get(options, :session_id, first.turn.session_id),
      turn_ref: "continued:#{Ecto.UUID.generate()}",
      status: :pending,
      submission: submission,
      submission_fingerprint: Submission.fingerprint(submission),
      inserted_at:
        DateTime.add(DateTime.utc_now(), System.unique_integer([:positive]), :millisecond)
    })
  end

  defp message(text, current) do
    %{
      "actor_ref" => "U123",
      "content" => %{"text" => text},
      "current" => current,
      "occurred_at" => "2026-10-16T09:00:00Z",
      "revision" => 1,
      "source_ref" => "slack-message:#{text}"
    }
  end

  # Each Work message row of a briefing card as it reads closed: its title,
  # count and note, which the page separates with a dot.
  defp rows(card) do
    card
    |> LazyHTML.query(~s(.prompt-group[data-group="conversation"] .prompt-source-main))
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query(".prompt-source-title, .prompt-source-count, .prompt-source-doc")
      |> Enum.map_join(" · ", &words(LazyHTML.text(&1)))
    end)
    |> Enum.filter(&String.starts_with?(&1, ["New messages", "Earlier in this request"]))
  end

  defp message_texts(document, turn) do
    document
    |> LazyHTML.query(
      "#request-#{turn.id} .prompt-source[data-source=earlier_in_request] .context-message .ui-message-body"
    )
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  defp text(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.text()
  defp words(text), do: text |> String.split() |> Enum.join(" ")

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
