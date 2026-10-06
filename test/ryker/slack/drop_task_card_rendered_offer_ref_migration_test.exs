defmodule Ryker.Slack.DropTaskCardRenderedOfferRefMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_006_090_000
  @offer_clause " AND ((rendered_publication_offer_ref IS NULL) OR " <>
                  "((char_length(rendered_publication_offer_ref) >= 1) AND " <>
                  "(char_length(rendered_publication_offer_ref) <= 256)))"

  # The column recorded a retired readiness click and nothing wrote it again
  # (2026-10-04 review). The check that named it is rebuilt without it, so the
  # test holds every other clause of the check where it was.
  test "a task card loses the retired offer column and nothing else in its check" do
    assert :ok = migrate_down(@version)
    assert "rendered_publication_offer_ref" in columns()
    before = check()
    assert before =~ @offer_clause

    assert :ok = migrate_up(@version)
    refute "rendered_publication_offer_ref" in columns()
    assert check() == String.replace(before, @offer_clause, "")
  end

  defp columns do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'slack_task_cards'",
        []
      )

    List.flatten(rows)
  end

  defp check do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'slack_task_card_valid'",
        []
      )

    definition
  end
end
