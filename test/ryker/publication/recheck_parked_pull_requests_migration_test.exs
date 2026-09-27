defmodule Ryker.Publication.RecheckParkedPullRequestsMigrationTest do
  @moduledoc """
  Found live 2026-09-27: releases before the ten-minute check parked every
  open pull request Ryker opened until 9999 after its first poll, and only a
  GitHub webhook could bring one back, on an install no webhook reaches. The
  pull request cited, AndrewDryga/test#2, would have stayed parked after the
  fix too. The migration makes each such open pull request due now, so its
  next poll puts it on the ten-minute timer; one that has ended stays parked.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{Followup, Followups}

  @version 20_260_927_172_000
  @migration Ryker.Repo.Migrations.RecheckParkedOpenPullRequests
  @file_name "20260927172000_recheck_parked_open_pull_requests.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @parked ~U[9999-01-01 00:00:00.000000Z]

  test "an open pull request an earlier release parked is checked at once, a merged one is not" do
    %{publication: open} = PublicationFixture.published!("parked-open")

    %{publication: merged} =
      PublicationFixture.published!("parked-merged", pull_request_number: 92)

    # What the releases before the fix left after each first poll.
    park!(open, "open")
    park!(merged, "merged")
    assert {:ok, nil} = Followups.claim_poll("migration:before", 60)

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)
    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert {:ok, %{publication: %{id: due}}} = Followups.claim_poll("migration:after", 60)
    assert due == open.id
    assert Repo.get_by!(Followup, publication_id: merged.id).next_poll_at == @parked
  end

  defp park!(publication, pr_state) do
    {1, nil} =
      Repo.update_all(
        from(followup in Followup, where: followup.publication_id == ^publication.id),
        set: [next_poll_at: @parked, pr_state: pr_state]
      )
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end
end
