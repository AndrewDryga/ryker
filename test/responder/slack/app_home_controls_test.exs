defmodule Responder.Slack.AppHomeControlsTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{AppHomeControls, HomeInteraction, HomeSubmission}

  @plan_fingerprint String.duplicate("a", 64)

  defmodule Directory do
    def user_allowed(%{allowed: allowed}, user_ref, _workspace_ref),
      do: {:ok, MapSet.member?(allowed, user_ref)}
  end

  defmodule ErrorDirectory do
    def user_allowed(_client, _user_ref, _workspace_ref), do: {:error, :directory_unavailable}
  end

  defmodule InvalidDirectory do
    def user_allowed(_client, _user_ref, _workspace_ref), do: :unknown
  end

  test "an operator mutates one typed resource and repaints Home" do
    parent = self()
    options = options(parent)

    assert {:ok, result} =
             AppHomeControls.handle(interaction(:forget_memory, "memory:one"), options)

    assert result.outcome == :forgotten
    assert result.resource_ref == "memory:one"
    assert_received {:forgot_memory, "memory:one", "U123", "T123"}
    assert_received {:refreshed_home, "U123", "T123"}

    assert {:ok, %{outcome: :paused}} =
             AppHomeControls.handle(
               interaction(:pause_schedule, "schedule-control:schedule:one:4"),
               options
             )

    assert_received {:set_schedule, "schedule:one", :paused, 4, "U123", "T123",
                     "interaction:home:1"}

    assert {:ok, %{outcome: :disabled}} =
             AppHomeControls.handle(
               interaction(:disable_behavior, "behavior-control:behavior:one:3"),
               options
             )

    assert_received {:set_behavior, "behavior:one", :disabled, 3, "U123", "T123",
                     "interaction:home:1"}

    assert {:ok, %{outcome: :merge}} =
             AppHomeControls.handle(
               interaction(:merge_memory_review, "memory-review:one"),
               options
             )

    assert_received {:memory_review, "memory-review:one", :merge, "U123", "slack:T123", nil}
  end

  test "a full nonoperator cannot mutate or repaint operational state" do
    parent = self()
    options = %{options(parent) | operators: MapSet.new()}

    assert AppHomeControls.handle(
             interaction(:delete_schedule, "schedule-control:schedule:one:4"),
             options
           ) ==
             {:ok, %{outcome: :denied}}

    refute_received {:set_schedule, _, _, _}
    refute_received {:refreshed_home, _, _}

    denied = %{options(parent) | client: %{allowed: MapSet.new()}}

    assert AppHomeControls.handle(
             interaction(:delete_schedule, "schedule-control:schedule:one:4"),
             denied
           ) ==
             {:ok, %{outcome: :denied}}
  end

  test "a stale private-channel control cannot mutate after the operator loses channel access" do
    options =
      options(self())
      |> Map.put(:authorize_resource, fn _interaction ->
        {:error, :app_home_resource_not_visible}
      end)

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule-control:schedule:one:4"),
             options
           ) == {:ok, %{outcome: :denied}}

    refute_received {:set_schedule, _, _, _, _, _, _}
    refute_received {:refreshed_home, _, _}
  end

  test "a stale or copied lifecycle button repaints once without asking Slack to retry" do
    parent = self()

    options =
      options(parent)
      |> Map.put(:forget_memory, fn _ref, _actor_ref, _workspace_ref ->
        {:error, :memory_workspace_mismatch}
      end)

    assert AppHomeControls.handle(interaction(:forget_memory, "memory:stale"), options) ==
             {:ok, %{outcome: :invalid, resource_ref: "memory:stale"}}

    assert_received {:refreshed_home, "U123", "T123"}
    refute_received {:forgot_memory, _, _}

    for {action, ref} <- [
          {:disable_behavior, "behavior:pre-upgrade"},
          {:pause_schedule, "schedule:pre-upgrade"}
        ] do
      assert AppHomeControls.handle(interaction(action, ref), options(parent)) ==
               {:ok, %{outcome: :invalid, resource_ref: ref}}

      assert_received {:refreshed_home, "U123", "T123"}
    end

    refute_received {:set_behavior, _, _, _, _, _, _}
    refute_received {:set_schedule, _, _, _, _, _, _}
  end

  # Opening the complete list must not be followed by the dashboard repaint
  # every mutating control ends with, or the list the operator asked for is
  # replaced by the digest it was meant to complete.
  test "opening a complete list publishes that page and leaves it on screen" do
    parent = self()
    options = options(parent)

    assert {:ok, %{outcome: :listed, resource_ref: "home-collection:schedules:0"}} =
             AppHomeControls.handle(
               interaction(:show_collection, "home-collection:schedules:0"),
               options
             )

    assert_received {:shown_collection, :schedules, 0, "U123", "T123"}
    refute_received {:refreshed_home, _, _}

    assert {:ok, %{outcome: :listed}} =
             AppHomeControls.handle(
               interaction(:show_collection, "home-collection:knowledge:20"),
               options
             )

    assert_received {:shown_collection, :knowledge, 20, "U123", "T123"}

    assert {:ok, %{outcome: :refreshed, resource_ref: "home-collection:dashboard"}} =
             AppHomeControls.handle(
               interaction(:show_dashboard, "home-collection:dashboard"),
               options
             )

    assert_received {:refreshed_home, "U123", "T123"}
    refute_received {:shown_collection, _, _, _, _}
  end

  test "a nonoperator cannot open a complete list, and a malformed page is not a request" do
    parent = self()

    assert AppHomeControls.handle(
             interaction(:show_collection, "home-collection:schedules:0"),
             %{options(parent) | operators: MapSet.new()}
           ) == {:ok, %{outcome: :denied}}

    refute_received {:shown_collection, _, _, _, _}

    for value <- [
          "home-collection:everything:0",
          "home-collection:schedules:-1",
          "home-collection:schedules:many",
          "home-collection:schedules",
          "home-collection:schedules:0:0"
        ] do
      assert AppHomeControls.handle(interaction(:show_collection, value), options(parent)) ==
               {:error, :app_home_control_mismatch}
    end

    refute_received {:shown_collection, _, _, _, _}

    assert AppHomeControls.handle(
             interaction(:show_collection, "home-collection:schedules:0"),
             Map.delete(options(parent), :show_collection)
           ) == {:error, {:invalid_app_home_control, :show_collection}}
  end

  test "a control that discovers schedule expiry settles and repaints as stale" do
    expired_receipt = {:ok, %{outcome: %{"status" => "expired"}}}

    options =
      options(self())
      |> Map.put(:set_schedule_status, fn _ref,
                                          _status,
                                          _revision,
                                          _actor,
                                          _workspace,
                                          _action_ref ->
        expired_receipt
      end)
      |> Map.put(:run_schedule, fn _ref, _actor, _workspace, _action_ref ->
        expired_receipt
      end)

    for interaction <- [
          interaction(:pause_schedule, "schedule-control:schedule:one:4"),
          interaction(:run_schedule, "schedule:one")
        ] do
      assert AppHomeControls.handle(interaction, options) ==
               {:ok, %{outcome: :invalid, resource_ref: interaction.resource_ref}}

      assert_received {:refreshed_home, "U123", "T123"}
    end
  end

  test "every typed behavior and schedule lifecycle action is host dispatched" do
    parent = self()
    options = options(parent)

    for {action, ref, outcome, message} <- [
          {:enable_behavior, "behavior-control:behavior:one:3", :active,
           {:set_behavior, "behavior:one", :active, 3, "U123", "T123", "interaction:home:1"}},
          {:delete_behavior, "behavior-control:behavior:one:3", :deleted,
           {:set_behavior, "behavior:one", :deleted, 3, "U123", "T123", "interaction:home:1"}},
          {:resume_schedule, "schedule-control:schedule:one:4", :active,
           {:set_schedule, "schedule:one", :active, 4, "U123", "T123", "interaction:home:1"}},
          {:delete_schedule, "schedule-control:schedule:one:4", :deleted,
           {:set_schedule, "schedule:one", :deleted, 4, "U123", "T123", "interaction:home:1"}}
        ] do
      assert {:ok, %{outcome: ^outcome, resource_ref: ^ref}} =
               AppHomeControls.handle(interaction(action, ref), options)

      assert_received ^message
      assert_received {:refreshed_home, "U123", "T123"}
    end
  end

  test "modal, run-now, publication, retained-work, and link controls stay typed and idempotent" do
    base = options(self())

    editor = %{interaction(:edit_memory_review, "memory-review:one") | trigger_ref: "trigger.1"}
    assert {:ok, %{outcome: :editing}} = AppHomeControls.handle(editor, base)

    assert_received {:opened_memory_editor, "memory-review:one", "trigger.1", "U123",
                     "slack:T123"}

    refute_received {:refreshed_home, _, _}

    assert {:ok, %{outcome: :edit}} = AppHomeControls.handle(submission(), base)

    assert_received {:memory_review, "memory-review:one", :edit, "U123", "slack:T123",
                     %{"subject" => "checkout-api", "value" => "Verify the SLO first."}}

    assert_received {:refreshed_home, "U123", "T123"}

    assert {:ok, %{outcome: :started}} =
             AppHomeControls.handle(interaction(:run_schedule, "schedule:one"), base)

    assert_received {:ran_schedule, "schedule:one", "U123", "T123", "interaction:home:1"}
    assert_received {:refreshed_home, "U123", "T123"}

    for {interaction_action, recovery_action} <- [
          {:retry_publication, :retry},
          {:update_publication, :update},
          {:discard_publication, :discard}
        ] do
      assert {:ok, %{outcome: ^recovery_action}} =
               AppHomeControls.handle(
                 interaction(interaction_action, "publication-recovery:one:3"),
                 base
               )

      assert_received {:recovered_publication, "publication:one", ^recovery_action, 3, "U123",
                       "T123", "interaction:home:1"}

      assert_received {:refreshed_home, "U123", "T123"}
    end

    assert {:ok, %{outcome: :discard_requested}} =
             AppHomeControls.handle(
               interaction(
                 :discard_workspace,
                 "responder-work-control:responder-work:episode:session:1:#{@plan_fingerprint}"
               ),
               base
             )

    assert_received {:discarded_workspace, "responder-work:episode:session:1", @plan_fingerprint,
                     "U123", "T123", "interaction:home:1"}

    assert_received {:refreshed_home, "U123", "T123"}

    assert {:ok, %{outcome: :opened}} =
             AppHomeControls.handle(interaction(:open_resource, "task-card:one"), base)

    refute_received {:refreshed_home, _, _}
  end

  test "memory review controls map every action and settle stale buttons" do
    base = options(self())

    for {action, resolved} <- [
          {:keep_memory_review, :keep},
          {:forget_memory_review, :forget}
        ] do
      assert {:ok, %{outcome: ^resolved}} =
               AppHomeControls.handle(interaction(action, "memory-review:one"), base)

      assert_received {:memory_review, "memory-review:one", ^resolved, "U123", "slack:T123", nil}
      assert_received {:refreshed_home, "U123", "T123"}
    end

    stale =
      Map.put(base, :resolve_memory_review, fn _ref, _action, _actor, _workspace, _replacement ->
        {:error, :memory_review_stale}
      end)

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               interaction(:keep_memory_review, "memory-review:stale"),
               stale
             )

    missing = Map.delete(base, :resolve_memory_review)

    assert AppHomeControls.handle(
             interaction(:keep_memory_review, "memory-review:missing"),
             missing
           ) == {:error, {:invalid_app_home_control, :resolve_memory_review}}
  end

  test "typed callback errors and malformed results fail closed" do
    base = options(self())

    editor = %{interaction(:edit_memory_review, "memory-review:one") | trigger_ref: "trigger.1"}

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               editor,
               Map.put(base, :open_memory_review_editor, fn _ref, _trigger, _actor, _workspace ->
                 {:error, :memory_review_cannot_edit}
               end)
             )

    assert AppHomeControls.handle(
             editor,
             Map.put(base, :open_memory_review_editor, fn _ref, _trigger, _actor, _workspace ->
               {:error, :database_unavailable}
             end)
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             editor,
             Map.put(base, :open_memory_review_editor, fn _ref, _trigger, _actor, _workspace ->
               :invalid
             end)
           ) == {:error, {:invalid_app_home_control, :open_memory_review_editor}}

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               interaction(:edit_memory_review, "memory-review:one"),
               base
             )

    assert AppHomeControls.handle(editor, Map.delete(base, :open_memory_review_editor)) ==
             {:error, {:invalid_app_home_control, :open_memory_review_editor}}

    assert AppHomeControls.handle(
             interaction(:keep_memory_review, "memory-review:one"),
             Map.put(base, :resolve_memory_review, fn _ref,
                                                      _action,
                                                      _actor,
                                                      _workspace,
                                                      _replacement ->
               {:error, :database_unavailable}
             end)
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             interaction(:keep_memory_review, "memory-review:one"),
             Map.put(base, :resolve_memory_review, fn _ref,
                                                      _action,
                                                      _actor,
                                                      _workspace,
                                                      _replacement ->
               :invalid
             end)
           ) == {:error, {:invalid_app_home_control, :resolve_memory_review}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.put(base, :forget_memory, fn _ref, _actor, _workspace ->
               {:error, :database_unavailable}
             end)
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.delete(base, :forget_memory)
           ) == {:error, {:invalid_app_home_control, :forget_memory}}

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               interaction(:disable_behavior, "behavior-control:behavior:one:3"),
               Map.put(
                 base,
                 :set_behavior_status,
                 fn _ref, _status, _revision, _actor, _workspace, _action_ref ->
                   {:error, :behavior_terminal}
                 end
               )
             )

    assert AppHomeControls.handle(
             interaction(:disable_behavior, "behavior-control:behavior:one:3"),
             Map.put(
               base,
               :set_behavior_status,
               fn _ref, _status, _revision, _actor, _workspace, _action_ref -> :invalid end
             )
           ) == {:error, {:invalid_app_home_control, :set_behavior_status}}

    assert AppHomeControls.handle(
             interaction(:disable_behavior, "behavior-control:behavior:one:3"),
             Map.put(
               base,
               :set_behavior_status,
               fn _ref, _status, _revision, _actor, _workspace, _action_ref ->
                 {:error, :database_unavailable}
               end
             )
           ) == {:error, :database_unavailable}

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               interaction(:pause_schedule, "schedule-control:schedule:one:4"),
               Map.put(
                 base,
                 :set_schedule_status,
                 fn _ref, _status, _revision, _actor, _workspace, _action_ref ->
                   {:error, :schedule_terminal}
                 end
               )
             )

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule-control:schedule:one:4"),
             Map.put(
               base,
               :set_schedule_status,
               fn _ref, _status, _revision, _actor, _workspace, _action_ref -> :invalid end
             )
           ) == {:error, {:invalid_app_home_control, :set_schedule_status}}

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule-control:schedule:one:4"),
             Map.delete(base, :set_schedule_status)
           ) == {:error, {:invalid_app_home_control, :set_schedule_status}}

    assert AppHomeControls.handle(
             interaction(:run_schedule, "schedule:one"),
             Map.put(base, :run_schedule, fn _ref, _actor, _workspace, _action_ref ->
               {:error, :database_unavailable}
             end)
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             interaction(:run_schedule, "schedule:one"),
             Map.put(base, :run_schedule, fn _ref, _actor, _workspace, _action_ref -> :invalid end)
           ) == {:error, {:invalid_app_home_control, :run_schedule}}

    assert AppHomeControls.handle(
             interaction(:run_schedule, "schedule:one"),
             Map.delete(base, :run_schedule)
           ) == {:error, {:invalid_app_home_control, :run_schedule}}

    assert {:ok, %{outcome: :invalid}} =
             AppHomeControls.handle(
               interaction(:retry_publication, "publication-recovery:one:1"),
               Map.put(base, :recover_publication, fn _ref,
                                                      _action,
                                                      _generation,
                                                      _actor,
                                                      _workspace,
                                                      _action_ref ->
                 {:error, :publication_not_found}
               end)
             )

    assert AppHomeControls.handle(
             interaction(:retry_publication, "publication-recovery:one:1"),
             Map.delete(base, :recover_publication)
           ) == {:error, {:invalid_app_home_control, :recover_publication}}

    assert AppHomeControls.handle(
             interaction(
               :discard_workspace,
               "responder-work-control:responder-work:one:session:1:#{@plan_fingerprint}"
             ),
             Map.delete(base, :discard_workspace)
           ) == {:error, {:invalid_app_home_control, :discard_workspace}}

    assert AppHomeControls.handle(
             interaction(:retry_publication, "publication-recovery:one:not-a-generation"),
             base
           ) == {:error, :app_home_control_mismatch}

    assert AppHomeControls.handle(
             interaction(:retry_publication, "publication-recovery:missing-generation"),
             base
           ) == {:error, :app_home_control_mismatch}
  end

  test "malformed authority, callbacks, and crossed resource kinds fail closed" do
    base = options(self())

    assert AppHomeControls.handle(:invalid, base) ==
             {:error, {:invalid_app_home_control, :request}}

    assert AppHomeControls.handle(interaction(:forget_memory, "behavior:one"), base) ==
             {:error, :app_home_control_mismatch}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             %{base | directory: ErrorDirectory}
           ) == {:error, :directory_unavailable}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             %{base | directory: InvalidDirectory}
           ) == {:error, {:invalid_app_home_control, :directory}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.delete(base, :directory)
           ) == {:error, {:invalid_app_home_control, :directory}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.put(base, :operators, :invalid)
           ) == {:error, {:invalid_app_home_control, :operators}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.put(base, :authorize_resource, fn _interaction -> :invalid end)
           ) == {:error, {:invalid_app_home_control, :authorize_resource}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.delete(base, :authorize_resource)
           ) == {:error, {:invalid_app_home_control, :authorize_resource}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.put(base, :forget_memory, fn _ref, _actor, _workspace -> :invalid end)
           ) == {:error, {:invalid_app_home_control, :forget_memory}}

    assert AppHomeControls.handle(
             interaction(:disable_behavior, "behavior-control:behavior:one:3"),
             Map.delete(base, :set_behavior_status)
           ) == {:error, {:invalid_app_home_control, :set_behavior_status}}

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule-control:schedule:one:4"),
             Map.put(
               base,
               :set_schedule_status,
               fn _ref, _status, _revision, _actor, _workspace, _action_ref ->
                 {:error, :database_unavailable}
               end
             )
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule-control:schedule:one:0"),
             base
           ) == {:error, :app_home_control_mismatch}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.delete(base, :refresh_home)
           ) == {:error, {:invalid_app_home_control, :refresh_home}}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.put(base, :refresh_home, fn _event -> :invalid end)
           ) == {:error, {:invalid_app_home_control, :refresh_home}}
  end

  defp interaction(action, resource_ref) do
    %HomeInteraction{
      action: action,
      actor_ref: "U123",
      event_ref: "interaction:home:1",
      occurred_at: ~U[2026-08-28 12:00:00Z],
      resource_ref: resource_ref,
      workspace_ref: "T123"
    }
  end

  defp submission do
    %HomeSubmission{
      action: :edit_memory_review,
      actor_ref: "U123",
      event_ref: "interaction:home-edit:1",
      occurred_at: ~U[2026-08-28 12:00:00Z],
      replacement: %{"subject" => "checkout-api", "value" => "Verify the SLO first."},
      resource_ref: "memory-review:one",
      workspace_ref: "T123"
    }
  end

  defp options(parent) do
    %{
      authorize_resource: fn _interaction -> :ok end,
      client: %{allowed: MapSet.new(["U123"])},
      directory: Directory,
      discard_workspace: fn ref, fingerprint, actor_ref, workspace_ref, action_ref ->
        send(
          parent,
          {:discarded_workspace, ref, fingerprint, actor_ref, workspace_ref, action_ref}
        )

        {:ok, %{status: :discard_requested}}
      end,
      forget_memory: fn ref, actor_ref, workspace_ref ->
        send(parent, {:forgot_memory, ref, actor_ref, workspace_ref})
        {:ok, %{ref: ref}}
      end,
      operators: MapSet.new(["U123"]),
      open_memory_review_editor: fn ref, trigger_ref, actor_ref, workspace_ref ->
        send(parent, {:opened_memory_editor, ref, trigger_ref, actor_ref, workspace_ref})
        :ok
      end,
      recover_publication: fn ref, action, generation, actor_ref, workspace_ref, action_ref ->
        send(
          parent,
          {:recovered_publication, ref, action, generation, actor_ref, workspace_ref, action_ref}
        )

        {:ok, %{status: action}}
      end,
      refresh_home: fn event ->
        send(parent, {:refreshed_home, event.actor_ref, event.workspace_ref})
        {:ok, %{outcome: :published}}
      end,
      resolve_memory_review: fn ref, action, actor_ref, workspace_ref, replacement ->
        send(parent, {:memory_review, ref, action, actor_ref, workspace_ref, replacement})
        {:ok, %{status: :resolved}}
      end,
      run_schedule: fn ref, actor_ref, workspace_ref, action_ref ->
        send(parent, {:ran_schedule, ref, actor_ref, workspace_ref, action_ref})
        {:ok, %{status: :started}}
      end,
      set_behavior_status: fn ref, status, revision, actor_ref, workspace_ref, action_ref ->
        send(
          parent,
          {:set_behavior, ref, status, revision, actor_ref, workspace_ref, action_ref}
        )

        {:ok, %{status: :recorded}}
      end,
      set_schedule_status: fn ref, status, revision, actor_ref, workspace_ref, action_ref ->
        send(
          parent,
          {:set_schedule, ref, status, revision, actor_ref, workspace_ref, action_ref}
        )

        {:ok, %{status: :recorded}}
      end,
      show_collection: fn event, kind, offset ->
        send(parent, {:shown_collection, kind, offset, event.actor_ref, event.workspace_ref})
        {:ok, %{access: :operator, outcome: :published}}
      end
    }
  end
end
