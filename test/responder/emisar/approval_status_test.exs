defmodule Responder.Emisar.ApprovalStatusTest do
  use ExUnit.Case, async: true

  alias Responder.Emisar.{ApprovalStatus, RunState}

  test "accepts every exact remote status and assigns a bounded human label" do
    for status <- RunState.statuses() do
      assert {:ok, prepared} = ApprovalStatus.prepare(document(status))
      assert prepared["status"] == status
      assert is_binary(ApprovalStatus.label(status))
    end
  end

  test "rejects crossed URLs, unknown status, and extra fields" do
    refute RunState.terminal?(:invalid)

    assert ApprovalStatus.prepare(%{document("success") | "run_url" => "http://example.test/run"}) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(%{document("success") | "status" => "invented"}) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(Map.put(document("success"), "approve", true)) ==
             {:error, {:invalid_emisar_approval_status, :document}}

    assert ApprovalStatus.prepare(:invalid) ==
             {:error, {:invalid_emisar_approval_status, :document}}
  end

  defp document(status) do
    %{
      "action_id" => "nomad.alloc_restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr-1",
      "expires_at" => "2099-08-29T12:00:00.000000Z",
      "operation_id" => "op-1",
      "pack_ref" => "nomad@1#sha256:abc",
      "remote_error" => nil,
      "request_id" => "apr-1",
      "run_id" => "run-1",
      "run_url" => "https://emisar.example/app/acme/runs/run-1",
      "runner_ref" => "production-runner",
      "status" => status
    }
  end
end
