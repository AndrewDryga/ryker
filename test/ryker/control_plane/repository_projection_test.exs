defmodule Ryker.ControlPlane.RepositoryProjectionTest do
  @moduledoc """
  What the Repositories pages read to draw a repository: the code its tasks
  last recorded and GitHub's side of it, read for the rows a page shows.
  """
  use Ryker.DataCase, async: false
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.RepositoryProjection
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.QueryWork
  alias Ryker.Settings
  alias Ryker.Work.{Session, Turn}

  @actor "control-plane:local"
  @repositories ~w(api billing checkout)

  setup do
    {:ok, snapshot} = Settings.initialize(@actor)

    Enum.reduce(@repositories, snapshot, fn ref, snapshot ->
      {:ok, snapshot} =
        Settings.put_repository(
          %{ref: ref, display_name: "acme/#{ref}", github_repository: "acme/#{ref}"},
          snapshot.installation.revision,
          @actor
        )

      {:ok, snapshot} =
        Settings.put_github_binding(
          %{
            name: ref,
            repository_ref: ref,
            installation_id: 10,
            repository_id: 20 + String.length(ref),
            ryker_actor_id: 30
          },
          snapshot.installation.revision,
          @actor
        )

      snapshot
    end)

    for ref <- @repositories do
      task!(ref, ~U[2026-10-01 08:00:00.000000Z], submission("1" <> ref, "recorded"))
      task!(ref, ~U[2026-10-02 08:00:00.000000Z], submission("2" <> ref, "recorded"))
      # The newest task recorded no receipt; the one before it is the last code.
      task!(ref, ~U[2026-10-03 08:00:00.000000Z], submission("3" <> ref, "unavailable"))
    end

    :ok
  end

  test "a repository's code is the last receipt its tasks recorded" do
    assert %{items: items, total: 3} = RepositoryProjection.list(%{})

    for %{ref: ref, freshness: freshness} <- items do
      assert freshness.resolved_revision == revision("2" <> ref)
      assert freshness.requested_revision == "refs/heads/main"
      assert freshness.recorded_at == ~U[2026-10-02 08:00:00.000000Z]
    end

    assert {:ok, %{freshness: %{resolved_revision: resolved}}} =
             RepositoryProjection.fetch("billing")

    assert resolved == revision("2billing")
  end

  # The list read the 500 newest tasks' whole prompts, up to 640 KB each, to
  # find one receipt in each, and read them again on every change to any
  # request (2026-10-04 review).
  test "the list reads each repository's receipt, not its tasks' prompts" do
    {%{items: [_, _, _]}, statements} =
      QueryWork.statements(fn -> RepositoryProjection.list(%{}) end)

    assert QueryWork.bytes_returned(statements, "episode_work_turns") < 10_000
  end

  # Five queries a repository read GitHub's deliveries for every repository
  # the list held, and the list shows none of it (2026-10-04 review).
  test "only a repository's page reads its GitHub deliveries, in one query" do
    {_list, statements} = QueryWork.statements(fn -> RepositoryProjection.list(%{}) end)
    assert QueryWork.count(statements, "github_repository_events") == 0

    {{:ok, detail}, statements} =
      QueryWork.statements(fn -> RepositoryProjection.detail("billing") end)

    assert QueryWork.count(statements, "github_repository_events") == 1

    assert detail.configured.github_health == %{
             duplicate_count: 0,
             failed: 0,
             last_event_at: nil,
             pending: 0
           }
  end

  # Every read of a repository's page read and redacted the prompt and answer
  # of its five newest knowledge runs, up to 2 MB each, though each sits in a
  # closed disclosure, and read them again on every change to any request
  # (2026-10-04 review).
  test "a repository's page reads a knowledge run's prompt only once it is opened" do
    Repo.insert!(%Ryker.RepositoryKnowledge.Entry{repository_ref: "billing"})
    for generation <- 1..5, do: knowledge_run!("billing", generation)

    {{:ok, %{knowledge_runs: runs}}, statements} =
      QueryWork.statements(fn -> RepositoryProjection.detail("billing") end)

    assert length(runs) == 5
    assert Enum.all?(runs, &(&1.prompt.text == nil and &1.prompt.bytes > 500_000))
    assert QueryWork.bytes_returned(statements, "repository_knowledge_runs") < 20_000

    [newest | _older] = runs
    opened = MapSet.new([newest.prompt.artifact_id])

    {{:ok, %{knowledge_runs: [newest | older]}}, statements} =
      QueryWork.statements(fn -> RepositoryProjection.detail("billing", opened) end)

    assert newest.prompt.text =~ "Write the knowledge for billing"
    assert newest.result.text == nil
    assert Enum.all?(older, &(&1.prompt.text == nil))
    assert QueryWork.bytes_returned(statements, "repository_knowledge_runs") < 1_500_000
  end

  # RYKER.md quotes the repository's own files, and its page showed it whole
  # while the run that wrote it was redacted (2026-10-04 review). A token in
  # it is shown redacted, as in the run's prompt and answer.
  test "a repository's RYKER.md is shown redacted" do
    token = "ghp_" <> String.duplicate("a1B2", 9)

    Repo.insert!(%Ryker.RepositoryKnowledge.Entry{
      repository_ref: "billing",
      document: "# RYKER.md\n\nRun `TOKEN=#{token} make deploy`.\n",
      document_sha256: String.duplicate("d", 64),
      document_commit: String.duplicate("a", 40),
      document_by: :model,
      document_at: ~U[2026-10-01 08:00:00.000000Z]
    })

    assert {:ok, %{knowledge: %{document: document}}} = RepositoryProjection.fetch("billing")
    assert document =~ "make deploy"
    refute document =~ token
  end

  defp knowledge_run!(repository, generation) do
    at = DateTime.add(~U[2026-10-01 08:00:00.000000Z], generation, :hour)

    Repo.insert!(%Ryker.RepositoryKnowledge.Run{
      id: Ecto.UUID.generate(),
      repository_ref: repository,
      generation: generation,
      status: :applied,
      source_commit: String.duplicate("a", 40),
      policy: "ryker-learning",
      policy_digest: String.duplicate("b", 64),
      transport: "github",
      conversation_ref: "github:acme/" <> repository,
      prompt:
        ~s({"instructions":"Write the knowledge for #{repository}.","files":") <>
          String.duplicate("lib/billing.ex ", 40_000) <> ~s("}),
      prompt_sha256: String.duplicate("c", 64),
      output_schema: %{"type" => "object"},
      manifest: %{},
      result: ~s({"purpose":"Billing."}),
      document: "# billing\n\nBilling.\n",
      started_at: at,
      inserted_at: at,
      updated_at: at
    })
  end

  defp task!(repository, at, submission) do
    id = Ecto.UUID.generate()

    assert {:ok, %{episode: episode}} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "repository-projection:" <> id,
                 native_input_id: "source:repository-projection:" <> id,
                 turn_ref: "turn:repository-projection:" <> id
               })
             )

    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        execution_kind: :work,
        policy: "engineering",
        policy_digest: String.duplicate("a", 64),
        repository_ref: repository,
        external_ref: "episode:#{episode.id}:session:1",
        generation: 1,
        create_generation: 1
      })

    Repo.insert!(%Turn{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      session_id: session.id,
      turn_ref: "work-turn:" <> id,
      status: :pending,
      submission: submission,
      submission_fingerprint: CanonicalJSON.digest(submission),
      inserted_at: at,
      updated_at: at
    })
  end

  # A task's prompt as Work freezes it: the workspace's receipt beside a
  # briefing of about 100 KB.
  defp submission(seed, status) do
    %{
      "briefing" => String.duplicate("Check the deploy. ", 5_600),
      "context" => %{
        "workspace" => %{
          "freshness" => %{
            "owner" => "coop",
            "repositories" => [
              %{
                "fetched_at" => "2026-10-01T07:59:00Z",
                "name" => "primary",
                "remote_identity" => "origin",
                "requested_revision" => "refs/heads/main",
                "resolved_revision" => revision(seed),
                "stale_base_revision" => nil,
                "stale_base_status" => "current",
                "version" => 2,
                "workspace_base_revision" => revision(seed)
              }
            ],
            "status" => status
          }
        }
      }
    }
  end

  defp revision(seed),
    do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower)
end
