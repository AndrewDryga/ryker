defmodule Ryker.CoopFleet.AccountUsageTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.{AccountUsage, ControlPlane, Worker}
  alias Ryker.Fixtures.CoopWorkers
  alias Ryker.Repo

  # The shape Coop publishes, byte for byte as its workerproto test marshals it
  # (internal/workerproto/account_usage_test.go): every key present, unknown as
  # null.
  @wire ~s({"version":1,"accounts":[) <>
          ~s({"account":"claude@work","sign_in":"not_signed_in","checked_at":null,"attempted_at":null,) <>
          ~s("error":null,"plan":null,"auth":null,"note":null,"limits":[],"reset_credits":null},) <>
          ~s({"account":"codex@personal","sign_in":"signed_in","checked_at":"2026-11-21T01:00:00Z",) <>
          ~s("attempted_at":"2026-11-21T01:05:00Z","error":"unavailable","plan":"pro","auth":null,"note":null,) <>
          ~s("limits":[{"name":"5-hour","used_percent":82,"remaining":null,"resets_at":"2026-11-21T03:00:00Z",) <>
          ~s("available":false,"note":null},{"name":"Credits","used_percent":null,"remaining":"unlimited",) <>
          ~s("resets_at":null,"available":null,"note":null}],) <>
          ~s("reset_credits":{"available":2,"expires_at":["2026-12-21T03:00:00Z"]}}]})

  test "a report Coop publishes is kept as it was sent" do
    usage = Jason.decode!(@wire)
    assert AccountUsage.normalize(usage) == usage
  end

  # It is display data: a report the controller cannot read must never refuse
  # the worker's poll, which would stop every command the worker carries.
  test "a report Ryker cannot read is dropped, never a refused poll" do
    usage = Jason.decode!(@wire)
    [unread, read] = usage["accounts"]
    limit = hd(read["limits"])

    for broken <- [
          %{usage | "version" => 2},
          Map.put(usage, "extra", true),
          %{usage | "accounts" => [read, read]},
          %{usage | "accounts" => [%{read | "account" => "codex@a/b"}]},
          %{usage | "accounts" => [%{read | "sign_in" => "maybe"}]},
          %{usage | "accounts" => [%{read | "error" => "boom"}]},
          %{usage | "accounts" => [%{unread | "checked_at" => "2026-11-21T01:00:00Z"}]},
          %{usage | "accounts" => [%{unread | "limits" => [limit]}]},
          %{usage | "accounts" => [%{read | "error" => nil}]},
          %{usage | "accounts" => [%{read | "limits" => [%{limit | "used_percent" => -1}]}]},
          %{
            usage
            | "accounts" => [%{read | "limits" => [%{limit | "name" => "5-hour\nweekly"}]}]
          },
          %{usage | "accounts" => [%{read | "plan" => String.duplicate("x", 257)}]},
          %{usage | "accounts" => [Map.delete(read, "note")]}
        ] do
      assert AccountUsage.normalize(broken) == nil, inspect(broken)
    end

    worker = worker!()
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker, usage))
    assert Repo.get!(Worker, worker).account_usage == usage

    broken = %{usage | "accounts" => [%{read | "sign_in" => "maybe"}]}
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker, broken))
    assert Repo.get!(Worker, worker).account_usage == usage
  end

  # A worker that has not read its providers since it started polls without the
  # report; the page keeps the last one, whose check times say how old it is.
  test "a poll without a report keeps the worker's last one" do
    usage = Jason.decode!(@wire)
    worker = worker!()
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker, usage))
    assert {:ok, _response} = ControlPlane.handle_poll_certificate(worker, poll(worker, nil))
    assert Repo.get!(Worker, worker).account_usage == usage
  end

  defp worker! do
    worker = "usage-worker-#{System.unique_integer([:positive])}"
    assert {:ok, _worker} = CoopWorkers.authorize(worker, "workspace-main", digest(worker))
    worker
  end

  defp poll(worker, usage) do
    hello = %{
      "build_version" => "coop-test",
      "capabilities" => [],
      "capacity" => %{
        "cooldown_until" => nil,
        "session_slots_free" => 1,
        "session_slots_total" => 1,
        "state" => "eligible",
        "turn_slots_free" => 1,
        "turn_slots_total" => 1,
        "workspace_slots_free" => 1,
        "workspace_slots_total" => 1
      },
      "clock_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "id" => worker,
      "protocol_version" => "2",
      "sandbox_digest" => String.duplicate("a", 64),
      "state" => "eligible",
      "workspace_ref" => "workspace-main"
    }

    %{
      "acknowledged_command_ids" => [],
      "command_results" => [],
      "event_batches" => [],
      "poll_ref" => "poll:#{worker}:#{System.unique_integer([:positive])}",
      "version" => 2,
      "worker" => if(usage, do: Map.put(hello, "account_usage", usage), else: hello)
    }
  end
end
