defmodule Responder.ControlPlane.UpdatesTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox

  alias Responder.ControlPlane.CardLabFeedback

  alias Responder.ControlPlane.Updates
  alias Responder.Repo

  test "rolled-back writes are invisible and committed changes invalidate live projections" do
    start_supervised!({Updates, []})
    Phoenix.PubSub.subscribe(Responder.ControlPlane.PubSub, "control-plane:card-lab")

    task =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          CardLabFeedback.record(
            "incident-room",
            "provisioning",
            "good",
            "Notification rollback check"
          )

          Repo.rollback(:test_rollback)
        end)
      end)

    assert Task.await(task) == {:error, :test_rollback}
    refute_receive :control_plane_changed, 150

    # NOTIFY commits independently without leaving a fixture in shared tables.
    task =
      unboxed_task(fn ->
        Repo.query!("SELECT pg_notify('responder_control_plane', 'card_lab_posts')")
      end)

    Task.await(task)
    assert_receive :control_plane_changed, 1_000
  end

  test "the notification payload contains no model, message, or credential data" do
    %{rows: [[definition]]} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT pg_get_functiondef('responder_control_plane_notify()'::regprocedure)")
      end)

    assert definition =~ "TG_TABLE_NAME"
    refute definition =~ "NEW."
    refute definition =~ "row_to_json"
  end

  test "each retained domain can invalidate its reader without publishing row contents" do
    tables = %{
      "execution_usage" => "usage",
      "episode_operator_reviews" => "timeline",
      "episode_schedules" => "schedules",
      "episode_event_subscriptions" => "subscriptions",
      "episode_state_records" => "memory",
      "episode_work_turns" => "timeline",
      "ingress_inbox_entries" => "admission",
      "admission_attempts" => "admission",
      "slack_incident_rooms" => "incident-rooms",
      "slack_channel_memberships" => "channels",
      "coop_workers" => "workspaces",
      "conversation_summaries" => "lab",
      "operational_memory_entries" => "memory",
      "memory_review_items" => "memory",
      "operator_behaviors" => "configuration",
      "standing_assignment_runs" => "rules",
      "platform_actions" => "timeline",
      "delivery_reactions" => "lab",
      "responder_operator_actions" => "failures",
      "future_table" => "configuration"
    }

    Enum.each(Enum.uniq(Map.values(tables)), fn domain ->
      Phoenix.PubSub.subscribe(Responder.ControlPlane.PubSub, "control-plane:#{domain}")
    end)

    for {table, reader} <- tables do
      state = %{connection: self(), reference: make_ref(), pending: MapSet.new(), timer: nil}

      {:noreply, state} =
        Updates.handle_info(
          {:notification, self(), state.reference, "responder_control_plane", table},
          state
        )

      assert MapSet.member?(state.pending, reader), "#{table} must refresh #{reader}"
      Process.cancel_timer(state.timer)
      {:noreply, flushed} = Updates.handle_info(:broadcast, state)
      assert flushed.pending == MapSet.new()
      assert flushed.timer == nil
      assert_receive :control_plane_changed
    end

    assert Updates.domain("/") == "activity"
    assert Updates.domain("/timeline/an-episode/model-calls") == "timeline"
    assert Updates.domain("/activity") == "activity"
  end

  test "room list and detail receive every invalidation for their displayed state" do
    for table <-
          ~w(slack_incident_rooms slack_channel_memberships episode_state_records episode_publications),
        path <- ["/incident-rooms", "/incident-rooms/incident%3Aone"] do
      state = %{connection: self(), reference: make_ref(), pending: MapSet.new(), timer: nil}

      {:noreply, pending} =
        Updates.handle_info(
          {:notification, self(), state.reference, "responder_control_plane", table},
          state
        )

      Process.cancel_timer(pending.timer)

      assert MapSet.member?(pending.pending, Updates.domain(path)),
             "#{table} must refresh #{path}"

      refute MapSet.member?(pending.pending, "incidents")
    end
  end
end
