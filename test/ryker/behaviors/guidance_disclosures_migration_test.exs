defmodule Ryker.Behaviors.GuidanceDisclosuresMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Corrections
  alias Ryker.StateTools.FixedTools
  alias Ryker.Work.Session

  @version 20_261_025_070_000

  # Existing native sessions cannot prove earlier explicit guidance reads.
  # A shape-only migration must preserve their frozen history without inventing receipts.
  test "existing sessions retain their history and have unproven guidance custody" do
    correction = Corrections.correction!()

    assert {:ok, _} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _ -> true end
             )

    claim = Corrections.later!(correction)
    assert claim.session.guidance_exposures == %{}
    assert migrate_down(@version) == :ok
    assert migrate_up(@version) == :ok
    assert Repo.get!(Session, claim.session.id).guidance_exposures == nil
    assert Repo.get!(Ryker.Work.Turn, claim.turn.id).submission == claim.turn.submission
  end
end
