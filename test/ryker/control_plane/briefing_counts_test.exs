defmodule Ryker.ControlPlane.BriefingCountsTest do
  @moduledoc """
  Counted partial rows on the briefing cards.

  A row that shows only what reached the model answers half the question. The
  other half — how many were eligible, and why the rest are missing — is only
  knowable while the selection is being made, so it is read from the ledger
  frozen beside the submission. Where no ledger exists the row says the
  selection was not recorded; an absence must never render as a zero, because
  "nothing matched" and "nobody looked" send an operator in opposite directions.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection}
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

    assert rendered(work.episode) =~ "48 eligible"
  end

  test "without a ledger the row says the selection was not recorded, never zero" do
    work = frozen!("no-ledger", nil)
    counts = counts(work.episode)

    refute counts["inputs"].known?
    assert counts["inputs"].label =~ "selection not recorded"
    refute counts["inputs"].label =~ "eligible"
    assert rendered(work.episode) =~ "selection not recorded"
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
    assert counts["candidates"].label =~ "5 checked"
    assert counts["candidates"].label =~ "2 offered"
    assert counts["candidates"].label =~ "3 not offered"
  end

  test "routing without a retained snapshot does not invent a search scope" do
    {entry, episode} = admitted!(nil)
    counts = admission_counts(episode, entry)

    refute counts["candidates"].known?
    assert counts["candidates"].label == "2 offered · search scope not recorded"
    refute counts["candidates"].label =~ "checked"
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

  defp admitted!(snapshot) do
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
          "context" => %{"candidates" => [%{"state" => "active"}, %{"state" => "complete"}]}
        }),
      "output_schema" => %{"type" => "object"}
    }

    Repo.insert!(%Ryker.Admission.Attempt{
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
end
