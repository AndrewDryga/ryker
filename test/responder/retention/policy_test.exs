defmodule Responder.Retention.PolicyTest do
  use Responder.DataCase, async: true

  alias Responder.Retention.Policy

  test "every migrated table has one explained retention owner" do
    tables =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
      ORDER BY table_name
      """)
      |> Map.fetch!(:rows)
      |> List.flatten()

    policies = Policy.all()
    policy_tables = Enum.map(policies, & &1.table)

    assert policy_tables == Enum.uniq(policy_tables)
    assert Enum.sort(policy_tables) == tables

    assert Enum.all?(
             policies,
             &(&1.class in [
                 :operational,
                 :conversation_memory,
                 :closed_work,
                 :episode_history,
                 :audit,
                 :cascade,
                 :kept
               ])
           )

    assert Enum.all?(policies, &(is_binary(&1.why) and String.trim(&1.why) != ""))
  end

  test "lookup never invents a policy" do
    assert {:ok, %{class: :operational}} = Policy.fetch("ingress_inbox_entries")
    assert :error = Policy.fetch("missing_table")
    assert :error = Policy.fetch(nil)
  end
end
