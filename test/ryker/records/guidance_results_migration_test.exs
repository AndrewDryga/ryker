defmodule Ryker.Records.GuidanceResultsMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Corrections
  alias Ryker.Records
  alias Ryker.StateTools.FixedTools

  @version 20_261_021_100_000

  test "adding guidance results preserves retained records and all other identity checks" do
    correction = Corrections.correction!()

    assert {:ok, saved} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _ -> true end
             )

    offer = Repo.fetch!(Records.Record.Query.by_ref(saved["record_ref"]))
    current = definition()
    assert current =~ "guidance_result"
    assert migrate_down(@version) == :ok
    previous = definition()
    refute previous =~ "guidance_result"
    assert String.replace(current, ", 'guidance_result'::text", "") == previous
    assert migrate_up(@version) == :ok
    assert definition() == current
    assert Repo.fetch!(Records.Record.Query.by_id(offer.id)) == offer
  end

  test "rollback refuses to strand retained correction evidence" do
    # Learned advice alone did not prevent the next omission; the durable
    # observation of whether a required output was established must survive.
    correction = Corrections.correction!()

    assert {:ok, saved} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _ -> true end
             )

    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]

    assert {:ok, evidence} =
             Records.create(later.state_token, "migration-evidence", "evidence", %{
               "claim_id" => "baseline",
               "source_name" => "deployment history",
               "source_type" => "emisar",
               "observation" => "Retained deployment history identifies the baseline.",
               "relation" => "supports"
             })

    assert {:ok, result} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 "guidance_ref" => saved["behavior_ref"],
                 "revision" => 1,
                 "requirement_ref" => requirement["requirement_ref"],
                 "status" => "blocked",
                 "detail" => "The proposed revision is unavailable in the authorized sources.",
                 "evidence_refs" => [evidence.ref]
               },
               binding: later
             )

    assert_raise Postgrex.Error,
                 ~r/guidance results exist; rollback would strand retained history/,
                 fn ->
                   migrate_down(@version)
                 end

    assert Repo.fetch!(Records.Record.Query.by_ref(result["record_ref"])).kind ==
             "guidance_result"
  end

  defp definition do
    %{rows: [[definition]]} =
      Repo.query!(
        """
        SELECT pg_get_constraintdef(oid) FROM pg_constraint
        WHERE conrelid = 'episode_state_records'::regclass
          AND conname = 'episode_state_record_identity_valid'
        """,
        []
      )

    definition
  end
end
