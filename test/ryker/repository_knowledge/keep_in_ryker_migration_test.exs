defmodule Ryker.RepositoryKnowledge.KeepInRykerMigrationTest do
  @moduledoc """
  Ryker keeps each repository's RYKER.md and proposes nothing (Andrew,
  2026-09-28: "I don't want to make daily PRs to update those files"). What
  only served proposing leaves: the pull request each entry followed, how its
  document reached GitHub, what was sent to a pull request's branch, and
  Work's copy of RYKER.md on the repository's settings row. Every document and
  every run stays; rolling back puts the columns back, and Work's copy from
  each document.
  """
  use Ryker.MigrationCase

  import Ryker.TestHelpers, only: [digest: 1]

  alias Ecto.Adapters.SQL

  @previous_version 20_260_928_160_000
  @version 20_260_928_200_000
  @commit String.duplicate("a", 40)
  @run_id "5f0b8c1e-2d4a-4c6b-9e7f-1a2b3c4d5e6f"
  @proposing ~w(published_at publication sent_sha256s pull_request_url pull_request_number
                pull_request_state)
  @work_copy ~w(knowledge_pull_request_url knowledge_content knowledge_status
                knowledge_source_commit knowledge_sha256)

  # The four repositories Ryker read on 2026-09-27 each had a draft pull
  # request open for knowledge Ryker already kept. Losing a document here
  # would cost a model reading the whole repository again, and Work would be
  # briefed with nothing meanwhile.
  test "every document and run stays, and nothing of a pull request does" do
    in_scratch_schema("knowledge_in_ryker", fn repo, prefix ->
      migrate!(repo, prefix, @previous_version)
      now = NaiveDateTime.utc_now()
      later = NaiveDateTime.add(now, 20 * 3_600)

      # emisar's document is open in a pull request, and Work reads it from
      # the settings row. ryker's is written and waits to be proposed. coop's
      # last proposal met a person's edit on its branch. test holds a RYKER.md
      # a person wrote, which the lane left alone and Work read as it was.
      person = "# How we work\n\nRun `make check`.\n"

      for {ref, copy} <- [
            {"emisar", %{content: document("emisar"), status: "proposed", url: pull(85)}},
            {"ryker", nil},
            {"coop", nil},
            {"test", %{content: person, status: "accepted", url: nil}}
          ] do
        insert!(repo, prefix, "repository_settings", repository(ref, copy, now))
      end

      insert!(
        repo,
        prefix,
        "repository_knowledge",
        entry("emisar", now, %{
          "document_run_id" => Ecto.UUID.dump!(@run_id),
          "published_at" => now,
          "publication" => "updated",
          "sent_sha256s" => [digest(document("emisar"))],
          "pull_request_url" => pull(85),
          "pull_request_number" => 85,
          "pull_request_state" => "open",
          "next_check_at" => later
        })
      )

      insert!(
        repo,
        prefix,
        "repository_knowledge",
        entry("ryker", now, %{"phase" => "publish", "next_attempt_at" => now})
      )

      insert!(
        repo,
        prefix,
        "repository_knowledge",
        entry("coop", now, %{
          "error_code" => "repository_knowledge_proposal_edited",
          "error" => "Someone edited RYKER.md on Ryker's pull request.",
          "next_check_at" => later
        })
      )

      insert!(repo, prefix, "repository_knowledge", %{
        "repository_ref" => "test",
        "next_check_at" => later,
        "inserted_at" => now,
        "updated_at" => now
      })

      insert!(repo, prefix, "repository_knowledge_runs", run("emisar", now))

      assert @version in migrate!(repo, prefix, @version)

      for column <- @proposing, do: refute(column?(repo, prefix, "repository_knowledge", column))
      for column <- @work_copy, do: refute(column?(repo, prefix, "repository_settings", column))

      # Every document stays, and so does the run that wrote one.
      assert documents(repo, prefix) == %{
               "coop" => document("coop"),
               "emisar" => document("emisar"),
               "ryker" => document("ryker"),
               "test" => nil
             }

      assert %{rows: [[run_document]]} =
               SQL.query!(repo, "SELECT document FROM #{prefix}.repository_knowledge_runs", [])

      assert run_document == document("emisar")

      # A document waiting to be proposed is the repository's knowledge now,
      # until tomorrow's check. One whose proposal was turned away is too,
      # and no longer says so. One Ryker never wrote, because a person's
      # RYKER.md held it back, is checked at once.
      assert schedule(repo, prefix) == %{
               "coop" => {"idle", nil, :now, nil},
               "emisar" => {"idle", nil, :later, nil},
               "ryker" => {"idle", nil, :tomorrow, nil},
               "test" => {"idle", nil, :now, nil}
             }

      assert_raise Postgrex.Error, ~r/repository_knowledge_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.repository_knowledge SET phase = 'publish' " <>
            "WHERE repository_ref = 'emisar'",
          []
        )
      end

      assert rollback!(repo, prefix) ==
               [@version]

      # The previous release finds each document as the one it last proposed.
      %{rows: copies} =
        SQL.query!(
          repo,
          """
          SELECT ref, knowledge_content, knowledge_status, knowledge_source_commit
          FROM #{prefix}.repository_settings ORDER BY ref
          """,
          []
        )

      assert copies == [
               ["coop", document("coop"), "proposed", @commit],
               ["emisar", document("emisar"), "proposed", @commit],
               ["ryker", document("ryker"), "proposed", @commit],
               ["test", nil, nil, nil]
             ]

      assert column?(repo, prefix, "repository_knowledge", "pull_request_state")
      assert documents(repo, prefix)["emisar"] == document("emisar")
    end)
  end

  defp document(ref),
    do: "# RYKER.md\n\nWritten by Ryker from `aaaaaaa` on 2026-09-27.\n\n## Purpose\n\n#{ref}.\n"

  defp pull(number), do: "https://github.com/acme/emisar/pull/#{number}"

  defp repository(ref, copy, now) do
    %{
      "ref" => ref,
      "github_repository" => "acme/#{ref}",
      "base_branch" => "main",
      "onboarding_state" => "ready",
      "source_commit" => @commit,
      "inserted_at" => now,
      "updated_at" => now
    }
    |> Map.merge(
      if copy,
        do: %{
          "knowledge_content" => copy.content,
          "knowledge_status" => copy.status,
          "knowledge_source_commit" => @commit,
          "knowledge_sha256" => digest(copy.content),
          "knowledge_pull_request_url" => copy.url
        },
        else: %{}
    )
  end

  # An entry holding a document a model wrote, as the knowledge lane left it.
  defp entry(ref, now, changes) do
    Map.merge(
      %{
        "repository_ref" => ref,
        "phase" => "idle",
        "document" => document(ref),
        "document_sha256" => digest(document(ref)),
        "document_commit" => @commit,
        "document_by" => "model",
        "document_at" => now,
        "inserted_at" => now,
        "updated_at" => now
      },
      changes
    )
  end

  defp run(ref, now) do
    %{
      "id" => Ecto.UUID.dump!(@run_id),
      "repository_ref" => ref,
      "generation" => 1,
      "status" => "applied",
      "source_commit" => @commit,
      "policy" => "ryker-repo-standard",
      "policy_digest" => String.duplicate("b", 64),
      "transport" => "github",
      "conversation_ref" => "github:#{ref}:repository:1",
      "prompt" => "{}",
      "prompt_sha256" => String.duplicate("b", 64),
      "output_schema" => "{}",
      "manifest" => "{}",
      "started_at" => now,
      "document" => document(ref),
      "dropped_count" => 0,
      "inserted_at" => now,
      "updated_at" => now
    }
  end

  defp insert!(repo, prefix, table, row) do
    columns = Map.keys(row)

    SQL.query!(
      repo,
      "INSERT INTO #{prefix}.#{table} (#{Enum.join(columns, ", ")}) VALUES (" <>
        Enum.map_join(1..length(columns), ", ", &"$#{&1}") <> ")",
      Enum.map(columns, &Map.fetch!(row, &1))
    )
  end

  defp documents(repo, prefix) do
    SQL.query!(repo, "SELECT repository_ref, document FROM #{prefix}.repository_knowledge", []).rows
    |> Map.new(fn [ref, document] -> {ref, document} end)
  end

  # Each entry's phase, when its next attempt is due, whether its next check
  # is due now, later today or tomorrow, and its error.
  defp schedule(repo, prefix) do
    SQL.query!(
      repo,
      """
      SELECT repository_ref, phase, next_attempt_at,
             extract(epoch FROM next_check_at - clock_timestamp())::integer, error
      FROM #{prefix}.repository_knowledge
      """,
      []
    ).rows
    |> Map.new(fn [ref, phase, attempt, seconds, error] ->
      due =
        cond do
          seconds <= 5 -> :now
          seconds in 86_000..86_400 -> :tomorrow
          true -> :later
        end

      {ref, {phase, attempt, due, error}}
    end)
  end

  defp column?(repo, prefix, table, column) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table, column]
      )

    exists?
  end
end
