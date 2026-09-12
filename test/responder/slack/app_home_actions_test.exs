defmodule Responder.Slack.AppHomeActionsTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.Publication, as: PublicationFixture
  alias Responder.Publication.{Followup, Publication}
  alias Responder.Repo
  alias Responder.Slack.{AppHomeActions, AppHomeProjection, HomeInteraction}
  alias Responder.State.{Schedule, ScheduleChangeset}
  alias Responder.Work.Custody

  @now ~U[2026-09-04 12:00:00.000000Z]

  defmodule SharedAPI do
    def shared_conversations(%{shared: shared}, _actor_ref, _workspace_ref),
      do: {:ok, shared}
  end

  defmodule ErrorSharedAPI do
    def shared_conversations(_client, _actor_ref, _workspace_ref),
      do: {:error, :slack_unavailable}
  end

  defmodule InvalidSharedAPI do
    def shared_conversations(_client, _actor_ref, _workspace_ref), do: :invalid
  end

  test "resource authorization rechecks exact user visibility before mutation" do
    %{publication: publication} =
      PublicationFixture.published!("app-home-visibility", conversation_ref: "slack:T123:C456")

    interaction = home_interaction(:retry_publication, "publication-recovery:#{publication.id}:1")

    assert AppHomeActions.authorize_resource(
             interaction,
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == :ok

    assert AppHomeActions.authorize_resource(
             interaction,
             SharedAPI,
             %{shared: MapSet.new(["GSECRET"])}
           ) == {:error, :app_home_resource_not_visible}

    assert AppHomeActions.authorize_resource(
             home_interaction(:forget_memory, "memory:one"),
             SharedAPI,
             %{shared: MapSet.new()}
           ) == :ok

    assert AppHomeActions.authorize_resource(
             home_interaction(:pause_schedule, "schedule:pre-upgrade"),
             SharedAPI,
             :must_not_query_slack
           ) == :ok

    assert AppHomeActions.authorize_resource(interaction, ErrorSharedAPI, :client) ==
             {:error, :slack_unavailable}

    assert AppHomeActions.authorize_resource(interaction, :not_an_api, :client) ==
             {:error, :app_home_resource_not_visible}

    assert AppHomeActions.authorize_resource(interaction, InvalidSharedAPI, :client) ==
             {:error, {:invalid_app_home_authorization, :shared_conversations}}

    assert AppHomeActions.authorize_resource(:not_an_interaction, SharedAPI, :client) ==
             {:error, {:invalid_app_home_authorization, :interaction}}

    assert AppHomeActions.authorize_resource(
             %{interaction | workspace_ref: "T999"},
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == {:error, :app_home_resource_not_visible}

    for malformed <- [
          home_interaction(:retry_publication, "publication-recovery:missing:1"),
          home_interaction(:retry_publication, "publication-recovery:malformed"),
          home_interaction(:discard_publication, "memory:one")
        ] do
      assert AppHomeActions.authorize_resource(
               malformed,
               SharedAPI,
               %{shared: MapSet.new(["C456"])}
             ) == {:error, :app_home_resource_not_visible}
    end

    schedule = schedule!(publication)

    for schedule_control <- [
          home_interaction(:run_schedule, schedule.ref),
          home_interaction(:pause_schedule, "schedule-control:#{schedule.ref}:1")
        ] do
      assert AppHomeActions.authorize_resource(
               schedule_control,
               SharedAPI,
               %{shared: MapSet.new(["C456"])}
             ) == :ok
    end

    for stale_schedule <- [
          home_interaction(:run_schedule, "schedule:missing"),
          home_interaction(:run_schedule, "memory:wrong-kind"),
          home_interaction(:pause_schedule, "schedule-control:malformed")
        ] do
      assert AppHomeActions.authorize_resource(
               stale_schedule,
               SharedAPI,
               %{shared: MapSet.new(["C456"])}
             ) == {:error, :app_home_resource_not_visible}
    end

    Repo.update_all(
      from(saved in Schedule, where: saved.id == ^schedule.id),
      set: [destination_conversation_ref: "control_plane:operator"]
    )

    assert AppHomeActions.authorize_resource(
             home_interaction(:run_schedule, schedule.ref),
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == {:error, :app_home_resource_not_visible}
  end

  test "publication recovery is fenced to the exact Slack workspace and action" do
    assert AppHomeActions.recover_publication(
             "publication:missing",
             :update,
             1,
             "U123",
             "T123",
             "interaction:publication:missing"
           ) == {:error, :publication_not_found}

    %{publication: publication} =
      PublicationFixture.published!("app-home-recovery", conversation_ref: "slack:T123:C456")

    Repo.update_all(
      from(saved in Publication, where: saved.id == ^publication.id),
      set: [expected_remote_head_sha: String.duplicate("8", 40)]
    )

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^publication.id),
      set: [pr_state: "stale"]
    )

    publication = Repo.get!(Publication, publication.id)

    assert Enum.any?(
             AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"])).needs_attention,
             fn row ->
               row.ref == publication.ref and row.title == "Implement app-home-recovery" and
                 row.controls == ["update", "discard"] and
                 row.url == "https://slack.com/app_redirect?team=T123&channel=C456"
             end
           )

    assert AppHomeActions.recover_publication(
             publication.ref,
             :update,
             publication.recovery_generation,
             "U123",
             "T999",
             "interaction:publication:crossed"
           ) == {:error, :publication_workspace_mismatch}

    assert {:ok, first} =
             AppHomeActions.recover_publication(
               publication.ref,
               :update,
               publication.recovery_generation,
               "U123",
               "T123",
               "interaction:publication:update"
             )

    assert first.status == :recorded
    assert first.actor_ref == "slack:user:U123"
    assert first.outcome["publication_ref"] == publication.ref

    assert {:ok, duplicate} =
             AppHomeActions.recover_publication(
               publication.ref,
               :update,
               publication.recovery_generation,
               "U123",
               "T123",
               "interaction:publication:update"
             )

    assert duplicate.status == :duplicate
    assert duplicate.outcome == first.outcome
  end

  test "retained-work discard cannot cross a Slack workspace and is idempotent" do
    assert AppHomeActions.discard_workspace(
             "responder-work:missing:session:1",
             String.duplicate("a", 64),
             "U123",
             "T123",
             "interaction:retention:missing"
           ) == {:error, :retention_session_not_found}

    session = retained_session!()

    visibility =
      home_interaction(
        :discard_workspace,
        "responder-work-control:#{session.external_ref}:#{session.discard_plan_fingerprint}"
      )

    assert AppHomeActions.authorize_resource(
             visibility,
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == :ok

    assert AppHomeActions.authorize_resource(
             visibility,
             SharedAPI,
             %{shared: MapSet.new(["GSECRET"])}
           ) == {:error, :app_home_resource_not_visible}

    assert AppHomeActions.authorize_resource(
             %{
               visibility
               | resource_ref:
                   "responder-work-control:responder-work:missing:session:1:#{String.duplicate("f", 64)}"
             },
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == {:error, :app_home_resource_not_visible}

    assert AppHomeActions.authorize_resource(
             %{visibility | resource_ref: "responder-work-control:malformed"},
             SharedAPI,
             %{shared: MapSet.new(["C456"])}
           ) == {:error, :app_home_resource_not_visible}

    assert Enum.any?(
             AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"])).needs_attention,
             fn row ->
               row.ref == session.external_ref and row.title == "Preserve this patch." and
                 row.controls == ["discard_workspace"] and
                 row.discard_plan_fingerprint == session.discard_plan_fingerprint and
                 row.url ==
                   "https://slack.com/app_redirect?team=T123&channel=C456&message_ts=1787832000.000100"
             end
           )

    assert AppHomeActions.discard_workspace(
             session.external_ref,
             session.discard_plan_fingerprint,
             "U123",
             "T999",
             "interaction:retention:crossed"
           ) == {:error, :retention_session_workspace_mismatch}

    assert AppHomeActions.discard_workspace(
             session.external_ref,
             String.duplicate("f", 64),
             "U123",
             "T123",
             "interaction:retention:stale"
           ) == {:error, :retention_discard_plan_stale}

    assert Repo.get!(Responder.Work.Session, session.id).cleanup_status == :retained

    assert {:ok, first} =
             AppHomeActions.discard_workspace(
               session.external_ref,
               session.discard_plan_fingerprint,
               "U123",
               "T123",
               "interaction:retention:discard"
             )

    assert first.outcome == :discard_requested
    assert first.action.actor_ref == "slack:user:U123"
    assert first.session.cleanup_status == :plan_pending

    assert {:ok, duplicate} =
             AppHomeActions.discard_workspace(
               session.external_ref,
               session.discard_plan_fingerprint,
               "U123",
               "T123",
               "interaction:retention:discard"
             )

    assert duplicate.outcome == :duplicate
    assert duplicate.session.id == first.session.id
  end

  test "newer unsafe retained work cannot hide an older discardable workspace" do
    eligible = retained_session!("eligible", true)

    Enum.each(1..8, fn index ->
      retained_session!("unsafe-#{index}", false)
    end)

    Repo.update_all(
      from(session in Responder.Work.Session, where: session.id == ^eligible.id),
      set: [updated_at: ~U[2000-01-01 00:00:00.000000Z]]
    )

    assert Enum.any?(
             AppHomeProjection.snapshot("T123", "U123", MapSet.new(["C456"])).needs_attention,
             fn row ->
               row.ref == eligible.external_ref and row.controls == ["discard_workspace"]
             end
           )
  end

  defp retained_session!(suffix \\ "app-home", safe? \\ true) do
    episode_id = Ecto.UUID.generate()
    episode_key = "app-home-retention:#{suffix}:#{episode_id}"
    turn_ref = "turn:app-home-retention:#{suffix}:#{episode_id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1787832000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "source:app-home-retention:#{suffix}:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "Preserve this patch."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(
               episode_id,
               "work-contributor",
               String.duplicate("a", 64),
               "responder"
             )

    plan = %{
      "operation_id" => "discard-plan:#{suffix}",
      "revision" => 8,
      "session_id" => "coop-session:#{suffix}",
      "workspace" => %{
        "accepted_dirty" => false,
        "accepted_unmerged" => false,
        "branch" => "responder/app-home",
        "dirty" => not safe?,
        "head" => String.duplicate("b", 40),
        "running" => false,
        "status_digest" => String.duplicate("c", 64),
        "unmerged" => safe?
      }
    }

    session
    |> Ecto.Changeset.change(%{
      cleanup_status: :retained,
      coop_session_id: "coop-session:#{suffix}",
      discard_plan: plan,
      discard_plan_fingerprint: Responder.CanonicalJSON.digest(plan),
      discard_plan_operation_id: plan["operation_id"],
      retained_reason: "unpublished_unmerged"
    })
    |> Repo.update!()
  end

  defp home_interaction(action, resource_ref) do
    %HomeInteraction{
      action: action,
      actor_ref: "U123",
      event_ref: "interaction:visibility",
      occurred_at: @now,
      resource_ref: resource_ref,
      workspace_ref: "T123"
    }
  end

  defp schedule!(publication) do
    id = Ecto.UUID.generate()

    %{
      authority: :read_only,
      confirmation_ref: "interaction:app-home-schedule",
      confirmed_at: @now,
      confirmed_by_actor_ref: "slack:user:U123",
      destination_conversation_ref: publication.destination_conversation_ref,
      destination_thread_ref: publication.destination_thread_ref,
      destination_transport: publication.destination_transport,
      id: id,
      next_occurrence_at: DateTime.add(@now, 86_400, :second),
      offer_record_id: publication.record_id,
      recurrence: %{
        "at" => DateTime.to_iso8601(DateTime.add(@now, 86_400, :second)),
        "kind" => "once"
      },
      ref: "schedule:#{id}",
      revision: 1,
      source_episode_id: publication.episode_id,
      status: :active,
      task: "Inspect current state.",
      timezone: "Etc/UTC",
      title: "Inspect current state"
    }
    |> ScheduleChangeset.insert()
    |> Repo.insert!()
  end
end
