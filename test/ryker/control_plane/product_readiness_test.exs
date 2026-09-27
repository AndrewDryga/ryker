defmodule Ryker.ControlPlane.ProductReadinessTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.ProductReadiness

  @profile %{
    policy: "ryker-chat",
    policy_digest: String.duplicate("a", 64),
    repository_ref: nil
  }

  test "a clean configured installation reports the real Chat and Slack state" do
    snapshot = %{slack: %{enabled: true}}

    ready_fleet =
      {:ok,
       %{
         eligible_workers: 1,
         required: true
       }}

    readiness =
      ProductReadiness.from(snapshot, ready_fleet, %{
        chat_profile: @profile,
        slack_configured: true,
        slack_connected: true
      })

    assert readiness.chat.state == :ready
    assert readiness.slack.state == :ready
  end

  test "saved connections never masquerade as runtime readiness" do
    snapshot = %{slack: %{enabled: true}}

    fleet = %{
      eligible_workers: 0,
      required: true
    }

    no_worker = {:ok, fleet}

    waiting =
      ProductReadiness.from(snapshot, no_worker, %{
        chat_profile: @profile,
        slack_configured: true,
        slack_connected: false
      })

    assert waiting.chat.state == :worker_unavailable
    assert waiting.slack.state == :worker_unavailable

    runtime_failed =
      ProductReadiness.from(
        snapshot,
        {:ok, %{fleet | eligible_workers: 1}},
        %{
          chat_profile: @profile,
          slack_configured: false,
          slack_connected: false
        }
      )

    assert runtime_failed.slack.state == :runtime_unavailable
  end

  test "settings application does not wait for a worker policy catalog" do
    readiness =
      ProductReadiness.from(
        %{slack: %{enabled: true}},
        {:ok, %{eligible_workers: 1, required: true}},
        %{chat_profile: nil}
      )

    assert readiness.chat.state == :setting_up
    assert readiness.chat.detail =~ "applying the saved work settings"
    refute readiness.chat.detail =~ "installing"
  end
end
