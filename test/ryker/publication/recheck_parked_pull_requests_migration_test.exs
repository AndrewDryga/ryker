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
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{Followup, Followups}

  @version 20_260_927_172_000
  @parked ~U[9999-01-01 00:00:00.000000Z]

  test "an open pull request an earlier release parked is checked at once, a merged one is not" do
    %{publication: open} = PublicationFixture.published!("parked-open")

    %{publication: merged} =
      PublicationFixture.published!("parked-merged", pull_request_number: 92)

    # What the releases before the fix left after each first poll.
    park!(open, :open)
    park!(merged, :merged)
    assert Followups.claim_poll("migration:before", 60) == {:ok, nil}

    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok

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
end
