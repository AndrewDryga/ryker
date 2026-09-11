defmodule Responder.Emisar.ApprovalContractTest do
  use ExUnit.Case, async: true

  alias Responder.Emisar.ApprovalContract

  @now ~U[2026-08-29 12:00:00.000000Z]

  test "only a future exact approval on the configured Emisar origin is authorized" do
    payload = approval()

    assert {:ok, prepared} =
             ApprovalContract.authorize(
               payload,
               "https://emisar.example/api/mcp/rpc",
               @now
             )

    assert prepared == payload

    assert {:ok, record} =
             ApprovalContract.prepare(payload, "record:emisar_approval:abc")

    assert record.continuation == %{
             "deadline_at" => payload["expires_at"],
             "kind" => "wait",
             "wait_kind" => "event",
             "wait_ref" => "record:emisar_approval:abc"
           }
  end

  test "foreign, ambiguous, expired, or identity-crossed approval links fail closed" do
    payload = approval()

    invalid = [
      %{payload | "approval_url" => "https://evil.example/app/acme/approvals/apr_123"},
      %{payload | "approval_url" => "http://emisar.example/app/acme/approvals/apr_123"},
      %{payload | "approval_url" => "https://user@emisar.example/app/acme/approvals/apr_123"},
      %{payload | "approval_url" => "https://emisar.example/app/acme/approvals/apr_123?q=1"},
      %{payload | "approval_url" => "https://emisar.example/app/acme/approvals/other"},
      %{payload | "status" => "success"},
      %{payload | "expires_at" => DateTime.to_iso8601(@now)}
    ]

    for candidate <- invalid do
      assert {:error, {:invalid_emisar_approval, _field}} =
               ApprovalContract.authorize(
                 candidate,
                 "https://emisar.example/api/mcp/rpc",
                 @now
               )
    end

    assert {:error, {:invalid_emisar_approval, :fields}} =
             payload
             |> Map.put("invented", true)
             |> ApprovalContract.authorize(
               "https://emisar.example/api/mcp/rpc",
               @now
             )
  end

  # The record is what the MODEL relays when it registers a hold; the review
  # receipt is what the HOST reads back from Emisar. Keeping the two documents
  # separate is what stops a relayed payload from supplying its own rationale,
  # command line or vote — text Emisar masks and counts nobody else can mint.
  test "a registration payload cannot carry review evidence the host must read from Emisar" do
    payload = approval()

    smuggled = [
      Map.put(payload, "review", %{"status" => "approved", "approved_count" => 2}),
      Map.put(payload, "reason", "Rotate the key"),
      Map.put(payload, "command", "rm -rf /"),
      Map.put(payload, "decisions", [])
    ]

    for candidate <- smuggled do
      assert ApprovalContract.authorize(
               candidate,
               "https://emisar.example/api/mcp/rpc",
               @now
             ) == {:error, {:invalid_emisar_approval, :fields}}
    end
  end

  defp approval do
    %{
      "action_id" => "nomad.restart",
      "approval_url" => "https://emisar.example/app/acme/approvals/apr_123",
      "expires_at" => "2026-08-29T13:00:00.000000Z",
      "operation_id" => "operation:123",
      "pack_ref" => "pack:nomad@3",
      "request_id" => "apr_123",
      "run_id" => "run_123",
      "runner_ref" => "runner:va1",
      "status" => "pending_approval"
    }
  end
end
