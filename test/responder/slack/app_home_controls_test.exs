defmodule Responder.Slack.AppHomeControlsTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{AppHomeControls, HomeInteraction}

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
    assert_received {:forgot_memory, "memory:one", "T123"}
    assert_received {:refreshed_home, "U123", "T123"}

    assert {:ok, %{outcome: :paused}} =
             AppHomeControls.handle(interaction(:pause_schedule, "schedule:one"), options)

    assert_received {:set_schedule, "schedule:one", :paused, "T123"}

    assert {:ok, %{outcome: :disabled}} =
             AppHomeControls.handle(interaction(:disable_behavior, "behavior:one"), options)

    assert_received {:set_behavior, "behavior:one", :disabled, "T123"}
  end

  test "a full nonoperator cannot mutate or repaint operational state" do
    parent = self()
    options = %{options(parent) | operators: MapSet.new()}

    assert AppHomeControls.handle(interaction(:delete_schedule, "schedule:one"), options) ==
             {:ok, %{outcome: :denied}}

    refute_received {:set_schedule, _, _, _}
    refute_received {:refreshed_home, _, _}
  end

  test "a stale or copied lifecycle button repaints once without asking Slack to retry" do
    parent = self()

    options =
      options(parent)
      |> Map.put(:forget_memory, fn _ref, _workspace_ref ->
        {:error, :memory_workspace_mismatch}
      end)

    assert AppHomeControls.handle(interaction(:forget_memory, "memory:stale"), options) ==
             {:ok, %{outcome: :invalid, resource_ref: "memory:stale"}}

    assert_received {:refreshed_home, "U123", "T123"}
    refute_received {:forgot_memory, _, _}
  end

  test "every typed behavior and schedule lifecycle action is host dispatched" do
    parent = self()
    options = options(parent)

    for {action, ref, outcome, message} <- [
          {:enable_behavior, "behavior:one", :active,
           {:set_behavior, "behavior:one", :active, "T123"}},
          {:delete_behavior, "behavior:one", :deleted,
           {:set_behavior, "behavior:one", :deleted, "T123"}},
          {:resume_schedule, "schedule:one", :active,
           {:set_schedule, "schedule:one", :active, "T123"}},
          {:delete_schedule, "schedule:one", :deleted,
           {:set_schedule, "schedule:one", :deleted, "T123"}}
        ] do
      assert {:ok, %{outcome: ^outcome, resource_ref: ^ref}} =
               AppHomeControls.handle(interaction(action, ref), options)

      assert_received ^message
      assert_received {:refreshed_home, "U123", "T123"}
    end
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
             Map.put(base, :forget_memory, fn _ref, _workspace -> :invalid end)
           ) == {:error, {:invalid_app_home_control, :forget_memory}}

    assert AppHomeControls.handle(
             interaction(:disable_behavior, "behavior:one"),
             Map.delete(base, :set_behavior_status)
           ) == {:error, {:invalid_app_home_control, :set_behavior_status}}

    assert AppHomeControls.handle(
             interaction(:pause_schedule, "schedule:one"),
             Map.put(base, :set_schedule_status, fn _ref, _status, _workspace ->
               {:error, :database_unavailable}
             end)
           ) == {:error, :database_unavailable}

    assert AppHomeControls.handle(
             interaction(:forget_memory, "memory:one"),
             Map.delete(base, :refresh_home)
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

  defp options(parent) do
    %{
      client: %{allowed: MapSet.new(["U123"])},
      directory: Directory,
      forget_memory: fn ref, workspace_ref ->
        send(parent, {:forgot_memory, ref, workspace_ref})
        {:ok, %{ref: ref}}
      end,
      operators: MapSet.new(["U123"]),
      refresh_home: fn event ->
        send(parent, {:refreshed_home, event.actor_ref, event.workspace_ref})
        {:ok, %{outcome: :published}}
      end,
      set_behavior_status: fn ref, status, workspace_ref ->
        send(parent, {:set_behavior, ref, status, workspace_ref})
        {:ok, %{ref: ref, status: status}}
      end,
      set_schedule_status: fn ref, status, workspace_ref ->
        send(parent, {:set_schedule, ref, status, workspace_ref})
        {:ok, %{ref: ref, status: status}}
      end
    }
  end
end
