defmodule Ryker.Publication.FollowupCheckTest do
  @moduledoc """
  Dropping `manual_check_ref` on 2026-09-30 silently dropped the one check that
  named it, and with it every rule PostgreSQL kept about a pull request
  follow-up: its states, its check counts, its merge commit and its
  verification. No test noticed for four days (2026-10-04 review).
  """
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.Followup

  test "PostgreSQL refuses a follow-up that breaks its own rules" do
    %{publication: publication} = PublicationFixture.published!("followup-check")
    followup = from(row in Followup, where: row.publication_id == ^publication.id)

    for broken <- [
          [checks_total: 1, checks_passed: 1, checks_failed: 1],
          [pr_state: "reopened"],
          [checks_state: "green"],
          [merge_sha: "not-a-commit"],
          [failure_count: -1]
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn -> Repo.update_all(followup, set: broken) end)
        end

      assert error.postgres.constraint == "episode_publication_followup_state_valid",
             "#{inspect(broken)} was accepted"
    end
  end
end
