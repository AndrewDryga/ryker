defmodule Ryker.StateTools.RelatedPublicationsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Fixtures.TaskOffer
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.StateTools.{Router, Tools}
  alias Ryker.Work.Custody

  setup do
    suffix = "linked-receipt-#{System.unique_integer([:positive])}"
    published = PublicationFixture.published!(suffix)
    destination = destination(published.episode)
    root = admit!("root:#{suffix}", destination)
    pin!(root.id)
    assert {:ok, root_claim} = Custody.claim_next("worker:#{suffix}:root", 60)
    assert root_claim.episode.id == root.id

    assert {:ok, offer} =
             Records.create(
               Records.token(root_claim.turn),
               "task-edge",
               "task_offer",
               TaskOffer.payload(%{"prompt" => "PRIVATE-task-prompt"})
             )

    change!(published.episode, linked_episode_id: root.id)

    offer =
      offer
      |> Records.Record.Changeset.confirm(%{
        confirmed_at: Repo.now!(),
        confirmed_by_actor_ref: "slack:user:U1",
        confirmed_episode_id: published.episode.id,
        confirmation_ref: "interaction:#{suffix}",
        status: :confirmed
      })
      |> Repo.update!()

    change!(published.publication,
      body: "PRIVATE-publication-body",
      review_patch: "PRIVATE-patch",
      last_error_detail: "PRIVATE-error"
    )

    followup = admit!("followup:#{suffix}", destination, root.id)
    pin!(followup.id)
    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}:followup", 60)
    assert claim.episode.id == followup.id

    %{claim: claim, root: root, root_claim: root_claim, offer: offer, published: published}
  end

  # QA127 could read the real draft from GitHub but its fresh linked episode
  # was told that no canonical publication receipt existed in this same thread.
  test "a fresh read-only followup sees its confirmed task receipt, not task authority",
       %{claim: claim, published: published, offer: offer} do
    assert {:ok, state} = work_state(claim)
    assert state["publication"] == nil
    assert [related] = state["related_publications"]
    assert related["context_only"] == true
    assert related["source_episode_ref"] == "episode:#{published.episode.id}"
    assert related["source_offer_ref"] == offer.ref
    assert related["published_revision"] == published.receipt
    assert related["status"] == "published"
    assert related["followup"]["checks_apply_to_current_review_candidate"] == "unknown"
    refute Jason.encode!(state) =~ "PRIVATE-"
    refute Map.has_key?(related, "approval_ref")
    refute Map.has_key?(related, "newer_implementation_recorded")
    assert state["records"] == []
  end

  # QA130's new thread retained an older request as contextual history. That
  # link must not hide the new request's own confirmed task and publication.
  test "a request linked to older context still sees its own confirmed task receipt",
       %{root: root, root_claim: root_claim, published: published} do
    ancestor =
      admit!(
        "older-context:#{System.unique_integer([:positive])}",
        %{destination(root) | thread_ref: "thread:older-context"}
      )

    change!(root, linked_episode_id: ancestor.id)
    assert {:ok, state} = work_state(root_claim)
    assert [related] = state["related_publications"]
    assert related["source_episode_ref"] == "episode:#{published.episode.id}"
    assert related["published_revision"] == published.receipt
  end

  test "caller-supplied publication scope stays narrower than related task context",
       %{claim: claim, published: published} do
    query = Publication.Publication.Query.by_id(published.publication.id)

    assert [{publication, _followup, _source_episode, _offer_ref}] =
             query
             |> Publication.Publication.Query.related_model_states(claim.episode, ["ryker"])
             |> Repo.all()

    assert publication.id == published.publication.id

    assert [] ==
             Publication.Publication.Query.by_id(Repo.generate_id())
             |> Publication.Publication.Query.related_model_states(claim.episode, ["ryker"])
             |> Repo.all()
  end

  test "related receipt disclosure requires the exact retained confirmed edge",
       %{claim: claim, published: published, root: root, offer: offer} do
    change!(published.episode, linked_episode_id: nil)
    assert_empty_related(claim)
    change!(published.episode, linked_episode_id: root.id)

    change!(offer,
      status: :open,
      confirmed_at: nil,
      confirmed_by_actor_ref: nil,
      confirmed_episode_id: nil,
      confirmation_ref: nil
    )

    assert_empty_related(claim)
  end

  test "a retained link cannot cross destination, execution mode or pruned history",
       %{claim: claim, root: root, published: published} do
    for source <- [root, published.episode],
        {field, foreign} <- [
          destination_transport: "control_plane",
          destination_conversation_ref: "slack:TFOREIGN:C456",
          destination_thread_ref: "thread:foreign",
          execution_mode: :shadow,
          history_pruned_at: Repo.now!()
        ] do
      change!(source, [{field, foreign}])
      assert_empty_related(claim)
      change!(source, [{field, Map.get(source, field)}])
    end
  end

  test "the current frozen repository set, not a linked task, grants receipt visibility",
       %{claim: claim} do
    frozen = claim.session.repository_context
    change!(claim.session, repository_context: %{frozen | "read_only_repositories" => []})
    assert_empty_related(claim)

    # PostgreSQL already refuses malformed stored contexts. A forged/stale
    # caller snapshot must fail closed too, never become a new repository set.
    session = %{claim.session | repository_context: %{}}
    assert Publication.ModelState.related(claim.episode, session) == []
    assert_empty_related(%{claim | session: session})
  end

  test "a stale caller cannot disclose related operational receipts", %{claim: claim} do
    change!(claim.session, generation: claim.session.generation + 1)
    assert work_state(claim) == {:error, "unauthorized"}
  end

  test "a tampered receipt or review is not promoted into trusted metadata",
       %{claim: claim, published: published} do
    change!(published.publication,
      publication_receipt_fingerprint: String.duplicate("0", 64),
      review_fingerprint: String.duplicate("0", 64)
    )

    assert {:ok, state} = work_state(claim)
    assert [related] = state["related_publications"]
    assert related["published_revision"] == nil
    assert related["review"] == nil
    assert related["existing_pull_request"]["number"] == 91
  end

  test "missing canonical edges and foreign publication destinations disclose no receipt",
       %{claim: claim, published: published, offer: offer} do
    change!(published.publication, destination_thread_ref: "thread:foreign")
    assert_empty_related(claim)

    change!(published.publication,
      destination_thread_ref: published.publication.destination_thread_ref
    )

    Repo.delete!(offer)
    assert_empty_related(claim)
  end

  test "related receipt context is bounded to three confirmed tasks",
       %{claim: claim, root: root, root_claim: root_claim} do
    newest =
      for index <- 1..3 do
        suffix = "bounded-receipt-#{index}-#{System.unique_integer([:positive])}"

        published =
          PublicationFixture.published!(suffix,
            conversation_ref: root.destination_conversation_ref,
            thread_ref: root.destination_thread_ref
          )

        change!(published.episode, linked_episode_id: root.id)

        assert {:ok, offer} =
                 Records.create(
                   Records.token(root_claim.turn),
                   "task-edge-#{index}",
                   "task_offer",
                   TaskOffer.payload(%{"prompt" => "PRIVATE-bounded-task-#{index}"})
                 )

        offer
        |> Records.Record.Changeset.confirm(%{
          confirmed_at: Repo.now!(),
          confirmed_by_actor_ref: "slack:user:U1",
          confirmed_episode_id: published.episode.id,
          confirmation_ref: "interaction:#{suffix}",
          status: :confirmed
        })
        |> Repo.update!()

        published.publication.ref
      end

    assert {:ok, state} = work_state(claim)
    assert length(state["related_publications"]) == 3
    assert Enum.sort(Enum.map(state["related_publications"], & &1["ref"])) == Enum.sort(newest)
    refute Jason.encode!(state) =~ "PRIVATE-"
  end

  defp assert_empty_related(claim) do
    assert {:ok, state} = work_state(claim)
    assert state["related_publications"] == []
  end

  defp work_state(claim) do
    options =
      Router.init(
        cursor_secret: Ryker.Secret.new("trusted-state-tools-token"),
        binding: %{
          episode: claim.episode,
          session: claim.session,
          state_token: Records.token(claim.turn),
          turn: claim.turn
        }
      )

    Tools.call("get_work_state", %{"limit" => 1}, options)
  end

  defp pin!(episode_id) do
    assert {:ok, session} =
             WorkSessions.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64),
               repository_ref: "emisar",
               repository_context: %{
                 "context_ref" => "repository-context:followup",
                 "parallel_goal_limit" => 1,
                 "primary_repository" => "emisar",
                 "read_only_repositories" => ["ryker"]
               }
             )

    session
  end

  defp admit!(key, destination, parent \\ nil) do
    id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination,
                 episode_id: id,
                 episode_key: key,
                 linked_episode_id: parent,
                 native_input_id: "source:#{key}",
                 occurred_at: Repo.now!(),
                 payload: %{"text" => "Read the recorded task result only."},
                 turn_ref: "turn:#{key}"
               })
             )

    Repo.get!(Episodes.Episode, id)
  end

  defp destination(episode) do
    %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
  end

  defp change!(row, changes) do
    row.__struct__
    |> Repo.get!(row.id)
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end
end
