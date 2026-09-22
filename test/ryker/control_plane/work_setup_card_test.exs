defmodule Ryker.ControlPlane.WorkSetupCardTest do
  @moduledoc """
  The Work setup card: what worker, session and workspace a turn actually ran on.

  The page used to render "Workspace selected" from the local Session row and
  its insertion time, which proves that configuration was pinned and nothing
  else: not that a remote session existed, not that a checkout was ready. Ready
  needs evidence of completed preparation, and a row that only proves selection
  says exactly that.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.{Custody, Session, Submission, Turn}

  @workspace %{
    "primary" => %{
      "base_commit" => String.duplicate("e36a37b", 6) |> binary_part(0, 40),
      "name" => "ryker",
      "path" => ".",
      "read_only" => false
    },
    "companions" => [
      %{
        "base_commit" => String.duplicate("9bc021a", 6) |> binary_part(0, 40),
        "name" => "coop",
        "path" => "../coop",
        "read_only" => true
      }
    ],
    "freshness" => []
  }

  test "a submitted turn is ready, with its session, worker and workspace" do
    work = submitted!("ready")
    html = rendered(work.episode)
    card = card(html, work.turn)
    document = LazyHTML.from_document(html)
    heading = LazyHTML.query(document, "#event-setup-#{work.turn.id} .case-card-heading")

    assert card =~ "Work setup"

    assert LazyHTML.query(heading, ".case-card-heading-main > h3") |> LazyHTML.text() ==
             "Work setup"

    assert LazyHTML.query(heading, ".case-card-heading-meta .success-mark") |> Enum.count() == 1
    # A success mark carries the state; the word is for assistive technology only.
    assert ready?(html, work.turn)
    refute card =~ "Ready"
    assert card =~ "Session"
    assert card =~ "New"
    assert card =~ "Execution policy"
    assert card =~ "setup-policy"
    assert card =~ "Worker"
    assert card =~ "Local Coop"
    assert card =~ "Workspace"
    assert card =~ "Prepared · 2 repositories"
    refute html =~ "Workspace selected"
  end

  test "setup details show access and tools without repeating face facts or internal receipts" do
    work = submitted!("details")
    html = rendered(work.episode)
    card = card(html, work.turn)

    location = html |> LazyHTML.from_document() |> LazyHTML.query(".episode-location")
    refute LazyHTML.text(location) =~ "ryker"

    assert card =~ "Setup details"
    assert card =~ "Generation 1"
    assert card =~ "Repository access"
    assert card =~ "ryker writable · coop read-only"
    assert card =~ "Ryker tools"
    assert card =~ "Bound to this work turn"
    refute card =~ "Selected from"
    refute card =~ "Preparation checks"
    refute card =~ "Technical details"
    refute card =~ "Policy digest"
    refute card =~ "Authority digest"

    labels =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#event-setup-#{work.turn.id} dt")
      |> Enum.map(&LazyHTML.text/1)

    assert Enum.count(labels, &(&1 == "Session")) == 1
    assert Enum.count(labels, &(&1 == "Execution policy")) == 1
    assert Enum.count(labels, &(&1 == "Worker")) == 1
    # The briefing owns the repo@sha chips and the tool catalog; setup does not repeat them.
    refute card =~ "e36a37be36a"
    refute card =~ "get_work_state"
  end

  test "a local session row alone is setup selected, not a ready worker" do
    # Pinning creates the Session row before any Work claim; the turn does not
    # exist yet. That row proves configuration was selected and nothing more.
    work = pinned!("selected")
    card = card(rendered(work.episode), work.session)

    assert card =~ "Setup selected"
    assert card =~ "Waiting for a Work claim"
    refute ready?(rendered(work.episode), work.session)
    refute card =~ "Worker"
  end

  test "an old turn with no preparation receipts keeps its outcome unrecorded" do
    work = claimed!("unrecorded")

    Repo.update_all(from(turn in Turn, where: turn.id == ^work.turn.id),
      set: [lease_ref: nil, lease_owner: nil, lease_expires_at: nil]
    )

    html = rendered(work.episode)
    card = card(html, work.turn)
    assert card =~ "Setup selected"
    assert card =~ "Preparation outcome not recorded"
    refute ready?(html, work.turn)
    refute card =~ "Preparing"
  end

  test "a claimed turn with no remote session yet is preparing, at its recorded step" do
    work = claimed!("preparing")
    html = rendered(work.episode)
    card = card(html, work.turn)

    assert card =~ "Preparing"
    assert card =~ "Creating worker session"
    refute ready?(html, work.turn)
  end

  test "a replaced session says so and keeps its reason unknown" do
    work = submitted!("replaced")

    Repo.update_all(from(session in Session, where: session.id == ^work.session.id),
      set: [generation: 2, create_generation: 3]
    )

    card = card(rendered(work.episode), work.turn)
    assert card =~ "Replaced"
    assert card =~ "Generation 2"
    assert card =~ "Reason not recorded"
    refute card =~ "reached its limit"
  end

  test "a later turn on the same session says the session was reused" do
    work = submitted!("reused")

    later =
      Repo.insert!(%Turn{
        id: Ecto.UUID.generate(),
        episode_id: work.episode.id,
        session_id: work.session.id,
        turn_ref: "reused-follow-up",
        status: :pending,
        coop_turn_id: "coop-turn-2",
        inserted_at: DateTime.add(DateTime.utc_now(), 1)
      })

    html = rendered(work.episode)
    assert card(html, work.turn) =~ "New"
    assert card(html, later) =~ "Reused from previous work round"
  end

  test "a turn blocked before it started shows the recorded cause, not a ready worker" do
    work = claimed!("blocked")

    # The dispatcher records the fleet's reason code and an inspected term; the
    # card says what that code means and never invents a per-worker breakdown.
    Repo.update_all(from(turn in Turn, where: turn.id == ^work.turn.id),
      set: [
        status: :blocked,
        last_error_code: "coop_worker_capacity_unavailable",
        last_error_detail: "{:coop_worker_capacity_unavailable, \"session\"}",
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    html = rendered(work.episode)
    card = card(html, work.turn)
    assert card =~ "Blocked"
    assert card =~ "No eligible worker with available capacity was found."
    assert card =~ "Failure diagnostics"
    refute card =~ "Policy digest"
    refute card =~ "Authority digest"
    refute card =~ "all workers were busy"
    refute ready?(html, work.turn)
  end

  defp ready?(html, %{id: id}) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-setup-#{id} .success-mark[aria-label='Ready']")
    |> Enum.count() == 1
  end

  defp card(html, %{id: id}) do
    LazyHTML.from_document(html)
    |> LazyHTML.query("#event-setup-#{id}")
    |> LazyHTML.text()
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

  defp pinned!(suffix) do
    episode_id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: episode_id,
          episode_key: "work-setup:#{suffix}:#{episode_id}",
          native_input_id: "source:#{suffix}:#{episode_id}",
          turn_ref: "turn:#{suffix}:#{episode_id}"
        })
      )

    {:ok, session} =
      Custody.pin_episode(
        episode_id,
        "setup-policy",
        String.duplicate("a", 64),
        String.duplicate("c", 64),
        "ryker"
      )

    %{episode: episode, session: session, turn: nil}
  end

  defp claimed!(suffix) do
    work = pinned!(suffix)
    {:ok, claim} = Custody.claim_next("setup:#{suffix}", 120, :work)
    %{work | turn: claim.turn} |> Map.put(:claim, claim)
  end

  defp submitted!(suffix) do
    work = claimed!(suffix)
    claim = work.claim

    {:ok, submission} =
      Submission.new(
        %{"mode" => "full", "workspace" => @workspace},
        "Investigate",
        %{"type" => "object"},
        "work-final-live-v2"
      )

    {:ok, _frozen} =
      Custody.freeze_submission(work.episode.id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        1,
        1,
        "coop-session-#{suffix}"
      )

    {:ok, turn} =
      Custody.bind_state_tools(
        work.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        "http://127.0.0.1:1/state",
        String.duplicate("d", 64)
      )

    {:ok, turn} =
      Custody.bind_turn(
        work.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        session.generation,
        1,
        "coop-turn-#{suffix}"
      )

    %{work | session: session, turn: turn}
  end
end
