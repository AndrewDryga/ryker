defmodule Ryker.ControlPlane.ModelUsageProjectionTest do
  use Ryker.DataCase, async: true
  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.ModelUsageProjection
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Work.Session

  @now ~U[2026-10-25 12:00:00.000000Z]

  # Owners could not tell whether Conversation or Deep ever ran. The same
  # model serves several categories, and a requested Deep job outside a
  # repository actually uses Conversation's settings.
  test "usage follows the executed category even when categories share a model" do
    for {policy, field} <- [
          {"ryker-chat", :conversation_models},
          {"ryker-env-team-app-deep", :deep_models},
          {"ryker-repo-app-standard", :standard_models},
          {"ryker-repo-app-contributor", :contributor_models},
          {"ryker-schedule-read-only", :schedule_models},
          {"ryker-incident", :incident_models},
          {"ryker-learning", :learning_models}
        ] do
      execution!(policy, @now)

      assert %{week: 1, month: 1, last_used_at: @now} =
               ModelUsageProjection.page(@now).categories[field]
    end

    execution!(nil, @now, kind: "admission")
    execution!("ryker-repo-retired-knowledge", @now, kind: "knowledge")
    execution!("ryker-learning", @now, kind: "improvement")
    usage = ModelUsageProjection.page(@now)
    assert usage.categories.routing_models.month == 1
    assert usage.categories.standard_models.month == 2
    assert usage.categories.learning_models.month == 2
    assert usage.unattributed == 0
  end

  test "recent usage excludes shadow and unmeasured attempts and counts each ledger entry once" do
    week = DateTime.add(@now, -7, :day)
    month = DateTime.add(@now, -30, :day)
    execution!("ryker-chat", @now)
    execution!("ryker-chat", week)
    execution!("ryker-chat", month)
    execution!("ryker-chat", DateTime.add(month, -1, :microsecond))
    execution!("ryker-chat", @now, execution_mode: "shadow")
    execution!("ryker-chat", @now, usage_recorded: false, status: "queued")
    execution!("ryker-chat", @now, usage_recorded: false, status: "failed")
    execution!("ryker-chat", DateTime.add(@now, 1, :second))

    # Reobserving a run updates its row, not the number of runs. The last
    # usage time is when it started, not when the host last updated it.
    run = execution!("ryker-chat", DateTime.add(@now, -60, :second))
    run |> Ecto.Changeset.change(updated_at: @now) |> Repo.update!()

    assert %{week: 3, month: 4, last_used_at: @now} =
             ModelUsageProjection.page(@now).categories.conversation_models
  end

  test "missing category history stays unknown instead of being inferred from a model" do
    execution!(nil, @now)
    usage = ModelUsageProjection.page(@now)
    assert usage.unattributed == 1

    assert Enum.all?(usage.categories, fn {_field, row} ->
             row == %{week: 0, month: 0, last_used_at: nil}
           end)
  end

  defp execution!(policy, at, attributes \\ []) do
    session_id =
      if policy do
        id = Ecto.UUID.generate()

        {:ok, %{episode: episode}} =
          Episodes.apply(
            EpisodeFixtures.admit_input(%{
              episode_id: id,
              episode_key: "model-usage:" <> id,
              native_input_id: "model-usage:" <> id,
              turn_ref: "model-usage:" <> id
            })
          )

        Repo.insert!(%Session{
          episode_id: episode.id,
          policy: policy,
          policy_digest: String.duplicate("a", 64),
          external_ref: "model-usage:" <> id
        }).id
      end

    Repo.insert!(
      struct!(
        Execution,
        Map.merge(
          %{
            kind: "work",
            source_id: Ecto.UUID.generate(),
            generation: "1",
            session_id: session_id,
            transport: "slack",
            conversation_ref: "slack:T123:C456",
            execution_mode: "live",
            status: "completed",
            execution_target: "codex:gpt-6.1-sol/high@default",
            usage_recorded: true,
            usage_input_tokens: 10,
            remote_started_at: at,
            recorded_at: at
          },
          Map.new(attributes)
        )
      )
    )
  end
end
