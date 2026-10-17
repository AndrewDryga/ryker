defmodule Ryker.Ingress.ReadOnlyRepositoryMessageMigrationTest do
  @moduledoc """
  A message is recorded in an environment that only reads some of its repositories. Its work
  profile names a read-only repository in `repositories` with no `policies`, which the inbox's
  check refused until 20261017120000: Chat answered such a message 409 (2026-10-17). A rollback
  must not strand a message the earlier check refuses.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  alias Ryker.ControlPlane.{Actions, ConversationLab}
  alias Ryker.Fixtures.ChannelEnvironments
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile

  @version 20_261_017_120_000
  @conversation_id "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

  test "a message in an environment with a read-only repository is recorded, and a rollback keeps it" do
    ChannelEnvironments.environment!("platform", %{is_default: true})

    ChannelEnvironments.environment!("bench", %{
      repositories: ["app", "docs"],
      access: %{"docs" => :read_only}
    })

    assert ConversationLab.select_environment(@conversation_id, "bench") == {:ok, "bench"}

    assert {:ok, %{entry: entry}} = send_message("Is the app healthy?")
    assert entry.work_profile["repositories"] == ["app", "docs"]
    assert Map.keys(entry.work_profile["policies"]) == ["app"]

    assert_raise Postgrex.Error,
                 ~r/only read some of their repositories are still recorded/,
                 fn ->
                   migrate_down(@version)
                 end

    Repo.delete_all(Entry)
    assert migrate_down(@version) == :ok

    assert {:error, {:persistence_failed, :ingress_input, [work_profile: {_message, refused}]}} =
             send_message("Is the app healthy now?")

    assert refused[:constraint_name] == "ingress_inbox_work_class_profile_valid"

    assert migrate_up(@version) == :ok
    assert {:ok, %{entry: _accepted}} = send_message("And now?")
  end

  # The app never builds a profile whose default repository work may not change, and the check
  # refuses one too: a CHECK passes a null, so without a test of its own the first repository's
  # missing policies would pass unseen.
  test "the first repository of an environment's profile must be one work may change" do
    ChannelEnvironments.environment!("platform", %{is_default: true})

    ChannelEnvironments.environment!("bench", %{
      repositories: ["app", "docs"],
      access: %{"docs" => :read_only}
    })

    assert ConversationLab.select_environment(@conversation_id, "bench") == {:ok, "bench"}
    assert {:ok, %{entry: entry}} = send_message("Is the app healthy?")
    reordered = Map.put(entry.work_profile, "repositories", ["docs", "app"])

    assert_raise Postgrex.Error, ~r/ingress_inbox_work_class_profile_valid/, fn ->
      Repo.query!(
        "UPDATE ingress_inbox_entries SET work_profile = $1, repository_ref = 'docs' WHERE id = $2",
        [Jason.encode!(reordered), Ecto.UUID.dump!(entry.id)]
      )
    end
  end

  defp send_message(text) do
    Actions.callbacks(placements(profile(["app", "docs"])), %{}).send_lab_message.(
      @conversation_id,
      text,
      [],
      nil
    )
  end

  # The profile the runtime assembles for the environment: policies for the repository work may
  # change, none for the one it only reads.
  defp profile(repositories) do
    class = %{policy: "bench-conversation", policy_digest: String.duplicate("c", 64)}

    {:ok, profile} =
      WorkProfile.new(%{
        environment_ref: "bench",
        parallel_goal_limit: 3,
        policies: %{"app" => %{conversational: class, standard: class, deep: class}},
        repositories: repositories
      })

    profile
  end

  defp placements(profile) do
    {:ok, outside} =
      WorkProfile.new(%{
        policy: "conversation-read",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    %{environments: %{"bench" => profile}, fallback_work_profile: outside}
  end
end
