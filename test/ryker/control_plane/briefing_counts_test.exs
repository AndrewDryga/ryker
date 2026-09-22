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

  test "a recorded ledger names eligible, included and each kind of omission" do
    work = frozen!("ledger", @ledger)
    counts = counts(work.episode)

    assert counts["inputs"].known?
    label = counts["inputs"].label
    assert label =~ "48 eligible"
    assert label =~ "2 current"
    assert label =~ "8 outside the history window"
    assert label =~ "8 cut to fit"

    # Included is counted from the frozen context, which is the exact set that
    # reached the model. This ledger claims thirty earlier messages; the request
    # contains one, and the request wins. A count of what was sent can only come
    # from what was sent.
    assert label =~ "1 earlier included"
    refute label =~ "30"

    refute rendered(work.episode) =~ "48 eligible"
  end

  test "without a ledger the row says the selection was not recorded, never zero" do
    work = frozen!("no-ledger", nil)
    counts = counts(work.episode)

    refute counts["inputs"].known?
    assert counts["inputs"].label =~ "selection not recorded"
    refute counts["inputs"].label =~ "eligible"
    refute rendered(work.episode) =~ "selection not recorded"
  end

  test "included counts still come from the frozen context when the ledger is absent" do
    work = frozen!("included-only", nil)
    counts = counts(work.episode)

    assert counts["inputs"].label =~ "2 current"
    assert counts["inputs"].label =~ "1 earlier included"
    assert counts["records"] == %{label: "0 included", known?: true}
  end

  test "a continuation counts current messages and never calls earlier ones omitted" do
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

    label = counts(work.episode)["current_inputs"].label
    assert label =~ "1 current"
    assert label =~ "4 earlier not resent"
    refute label =~ "omitted"
  end

  test "routing counts what the bounded search checked against what it offered" do
    {entry, episode} = admitted!(%{"conversation_episode_count" => 5, "candidates" => []})
    counts = admission_counts(episode, entry)

    assert counts["candidates"].known?
    assert counts["candidates"].label == "2/5 supplied to routing"
    assert counts["candidates"].excluded == 3
    assert is_binary(counts["candidates"].reason)
  end

  test "routing without a retained snapshot does not invent a search scope" do
    {entry, episode} = admitted!(nil)
    counts = admission_counts(episode, entry)

    refute counts["candidates"].known?
    assert counts["candidates"].label == "2 supplied to routing · eligible set not recorded"
    refute counts["candidates"].label =~ "/"
  end

  test "related episode history is lazy, cutoff-fenced and loaded in one bounded query" do
    candidate_id = Ecto.UUID.generate()
    candidate_ref = "candidate:#{String.duplicate("c", 64)}"
    candidate_key = "candidate-history:#{candidate_id}"

    history_entries =
      Enum.map(1..25, fn index ->
        {input, entry} = recorded_history_input!(candidate_id, index)

        {:ok, %{episode: candidate_episode}} =
          Episodes.apply(
            EpisodeFixtures.admit_input(%{
              episode_id: candidate_id,
              episode_key: candidate_key,
              native_input_id: input.native_input_id,
              occurred_at: input.occurred_at,
              payload: Ryker.Ingress.Input.document(input),
              turn_ref: "candidate-history-turn:#{index}:#{candidate_id}"
            })
          )

        entry = associate_history_entry!(entry, candidate_episode.id)
        {entry, candidate_episode}
      end)

    candidate_episode = history_entries |> hd() |> elem(1)

    built_at = DateTime.utc_now()
    covered_through = DateTime.add(@now, 25, :second) |> DateTime.to_iso8601()

    {late_input, late_entry} =
      recorded_history_input!(candidate_id, 26,
        text: "Late backfilled message",
        occurred_at: DateTime.add(@now, 10, :second)
      )

    {:ok, _late_transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: candidate_id,
          episode_key: candidate_key,
          native_input_id: late_input.native_input_id,
          occurred_at: late_input.occurred_at,
          payload: Ryker.Ingress.Input.document(late_input),
          turn_ref: "candidate-history-turn:26:#{candidate_id}"
        })
      )

    associate_history_entry!(late_entry, candidate_episode.id)

    preview = fn text, at ->
      %{
        "content_preview" => Jason.encode!(message_payload(text)),
        "occurred_at" => DateTime.to_iso8601(at),
        "truncated" => false
      }
    end

    candidate = %{
      "allowed_relations" => ["same_work", "history_only"],
      "digest" => %{
        "conversations" => 1,
        "covered_through" => covered_through,
        "freshness" => "current",
        "input_count" => 25,
        "latest_development" => nil,
        "objective" => "Investigate candidate history"
      },
      "episode_ref" => candidate_ref,
      "first_input" => preview.("History message 1", @now),
      "latest_input" => preview.("History message 25", DateTime.add(@now, 25, :second)),
      "match" => %{"same_thread" => true},
      "same_thread" => true,
      "source_owner" => false,
      "state" => "complete"
    }

    snapshot = %{
      "built_at" => DateTime.to_iso8601(built_at),
      "candidates" => [Map.put(candidate, "episode_id", candidate_episode.id)],
      "conversation_episode_count" => 1
    }

    {entry, _episode} = admitted!(snapshot, [candidate])
    artifact_id = "candidate-history-#{entry.id}-#{candidate_episode.id}"
    handler = "candidate-history-query:#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        &__MODULE__.record_candidate_history_query/4,
        self()
      )

    try do
      assert {:ok, collapsed} = ModelRequests.project_input(entry.id, %{})
      history = collapsed.selected.counts["candidate_histories"][candidate_ref]
      assert history == %{"artifact_id" => artifact_id, "state" => "collapsed"}
      refute_receive {:candidate_history_query, _query}, 0

      assert {:ok, opened} =
               ModelRequests.project_input(entry.id, %{"disclosed" => [artifact_id]})

      assert_receive {:candidate_history_query, _query}
      refute_receive {:candidate_history_query, _query}, 0

      history = opened.selected.counts["candidate_histories"][candidate_ref]
      assert history["state"] == "retained"
      assert history["omitted"] == 5
      assert length(history["items"]) == 20
      assert hd(history["items"])["content_preview"] =~ "History message 1"
      assert hd(history["items"])["history_position"] == 1
      refute Enum.any?(history["items"], &(&1["content_preview"] =~ "History message 2\""))
      assert List.last(history["items"])["content_preview"] =~ "History message 25"
      assert List.last(history["items"])["history_position"] == 25
      refute Enum.any?(history["items"], &(&1["content_preview"] =~ "Late backfilled message"))

      {last_entry, _episode} = List.last(history_entries)

      last_entry
      |> Ecto.Changeset.change(operational_pruned_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:ok, after_pruning} =
               ModelRequests.project_input(entry.id, %{"disclosed" => [artifact_id]})

      history = after_pruning.selected.counts["candidate_histories"][candidate_ref]
      refute Enum.any?(history["items"], &(&1["content_preview"] =~ "History message 25"))

      first_attempt = Repo.get_by!(Attempt, input_id: entry.id, generation: 1)

      Repo.insert!(%Attempt{
        generation: 2,
        input_id: entry.id,
        phase: "response_received",
        policy: first_attempt.policy,
        policy_digest: first_attempt.policy_digest,
        submission: first_attempt.submission,
        submission_fingerprint: first_attempt.submission_fingerprint
      })

      entry
      |> Ecto.Changeset.change(
        admission_context:
          put_in(snapshot, ["candidates", Access.at(0), "digest", "input_count"], 26),
        execution_generation: 2
      )
      |> Repo.update!()

      assert {:ok, older_generation} =
               ModelRequests.project_input(entry.id, %{
                 "generation" => "1",
                 "disclosed" => [artifact_id]
               })

      assert older_generation.selected.generation == 1
      assert older_generation.selected.counts["candidate_histories"] == %{}

      html =
        render_component(&RequestPage.render/1,
          view: opened,
          params: %{},
          path: "/timeline/#{entry.id}"
        )

      document = LazyHTML.from_document(html)
      related = LazyHTML.query(document, ".candidate-related-history")
      assert LazyHTML.attribute(related, "data-artifact") == [artifact_id]
      assert LazyHTML.text(related) =~ "Full history not supplied to routing"
      assert Enum.count(LazyHTML.query(related, ".candidate-preview")) == 20

      labels =
        related
        |> LazyHTML.query(".candidate-preview header strong")
        |> Enum.map(&LazyHTML.text/1)

      assert "Message 1" in labels
      assert "Message 7" in labels
      assert "Message 25" in labels
      refute Enum.any?(2..6, &("Message #{&1}" in labels))
    after
      :telemetry.detach(handler)
    end
  end

  defp counts(episode) do
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    Enum.find_value(timeline.items, %{}, &(&1.source_kind == :work && &1[:counts]))
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
        "work-final-live-v2"
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

  def record_candidate_history_query(_event, _measurements, %{query: query}, owner) do
    if self() == owner and String.contains?(query, "episode_kernel_events") and
         String.contains?(query, "row_number"),
       do: send(owner, {:candidate_history_query, query})
  end

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

  defp message_payload(text) do
    %{
      "actor" => %{"kind" => "user", "ref" => "U123"},
      "content" => %{"text" => text},
      "event_kind" => "message"
    }
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
