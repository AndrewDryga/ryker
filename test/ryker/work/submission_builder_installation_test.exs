defmodule Ryker.Work.SubmissionBuilderInstallationTest do
  # The submission builder's tests that save settings. The one installation
  # row is held for the whole sandboxed test, so these run serially, and the
  # builder's other tests run async (submission_builder_test.exs, since
  # 2026-10-14).
  use Ryker.DataCase, async: false
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.{Episodes, Settings}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Inspectors
  alias Ryker.Work.Custody

  @now DateTime.utc_now()

  # Andrew, 2026-09-28: "I don't want to make daily PRs to update those
  # files." Work was briefed only from a copy of RYKER.md on the repository's
  # settings row, which the knowledge lane saved when it proposed a document
  # in a pull request or read the file its default branch held. Without a
  # proposal nothing would write that copy again, and every task would start
  # without what Ryker knows about its repository. Work is briefed from the
  # document Ryker keeps, the moment it is written.
  test "Work is briefed with knowledge that was never proposed" do
    content =
      "# RYKER.md\n\nWritten by Ryker from `bbbbbbb` on 2026-09-28.\n\n## Purpose\n\n" <>
        "Use `mix test` for focused checks.\n"

    commit = String.duplicate("b", 40)
    sha256 = digest(content)
    {:ok, settings} = Settings.initialize("control-plane:local")

    assert {:ok, _settings} =
             Settings.put_repository(
               %{
                 ref: "knowledge-repo",
                 github_repository: "owner/knowledge-repo",
                 base_branch: "main"
               },
               settings.installation.revision,
               "control-plane:local"
             )

    Repo.insert!(%Ryker.RepositoryKnowledge.Entry{
      repository_ref: "knowledge-repo",
      document: content,
      document_sha256: sha256,
      document_commit: commit,
      document_by: :model,
      document_at: Repo.now!()
    })

    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-submission:repository-knowledge:#{id}",
        native_input_id: "source:repository-knowledge:#{id}",
        occurred_at: @now,
        payload: %{"text" => "Review the repository"},
        turn_ref: "turn:repository-knowledge:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64),
               repository_ref: "knowledge-repo"
             )

    assert {:ok, claim} = Custody.claim_next("worker:repository-knowledge", 60)
    assert {:ok, submission} = Inspectors.submission(claim)

    # The document, the commit it was written from and its digest: no path
    # in the repository, since the repository holds no copy of it.
    assert submission["context"]["repository_knowledge"] == %{
             "content" => content,
             "sha256" => sha256,
             "source_commit" => commit
           }

    assert submission["prompt"] =~ "Use `mix test`"
  end

  test "an access briefing names only the environment and repositories this work has" do
    # A two-minute live answer named internal repository codes and omitted the
    # environment altogether (manual qualification, 2026-10-11). The model needs
    # names people recognize without treating display metadata as new authority.
    {:ok, _} = Settings.initialize("control-plane:local")

    for {ref, name} <- [
          {"qa-primary", "example/app"},
          {"qa-docs", "example/docs"},
          {"qa-other", "example/unrelated"}
        ] do
      assert {:ok, _} =
               Settings.put_repository(
                 %{ref: ref, github_repository: name},
                 :current,
                 "control-plane:local"
               )
    end

    assert {:ok, _} =
             Settings.put_environment(
               %{
                 ref: "qa-environment",
                 display_name: "Practice",
                 repositories: ["qa-primary", "qa-docs", "qa-other"]
               },
               :current,
               "control-plane:local"
             )

    claim =
      claim_episode!("connected-names", "What environment and repository access do you have?")

    session = %{
      claim.session
      | environment_ref: "qa-environment",
        repository_ref: "qa-primary",
        repository_context: %{
          "primary_repository" => "qa-primary",
          "read_only_repositories" => ["qa-docs"]
        }
    }

    assert {:ok, submission} =
             Inspectors.submission(%{claim | session: session},
               connected: %{github: true, slack: true}
             )

    connected = submission["context"]["connected"]
    assert connected["environment"] == %{"ref" => "qa-environment", "name" => "Practice"}
    assert connected["repositories"] == ["qa-primary", "qa-docs"]

    assert connected["repository_names"] == %{
             "qa-primary" => "example/app",
             "qa-docs" => "example/docs"
           }

    refute submission["prompt"] =~ "example/unrelated"
  end

  defp claim_episode!(suffix, text) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-submission:#{suffix}:#{id}",
        native_input_id: "source:#{suffix}:#{id}",
        occurred_at: @now,
        payload: %{"text" => text},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64)
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    claim
  end
end
