defmodule Ryker.CoopFleet.ModelRequestTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.ModelRequest

  @job %{"targets" => ["codex:gpt-6.2-sol/medium@work"]}

  test "native interrupt uses the pinned Codex control without creating another inference" do
    body =
      Jason.encode!(%{
        "type" => "response.interrupt",
        "response_id" => "resp_native",
        "mode" => "discard_partial_items"
      })

    assert ModelRequest.websocket(@job, "codex", "work", body) ==
             {:ok, %{kind: :interrupt, lane: nil, response_id: "resp_native"}}

    for extra <- [%{"type" => "response.cancel"}, %{"mode" => "invented"}, %{"response_id" => ""}] do
      {:ok, original} = Jason.decode(body)

      assert ModelRequest.websocket(
               @job,
               "codex",
               "work",
               Jason.encode!(Map.merge(original, extra))
             ) == {:error, :model_target_refused}
    end
  end

  test "parallel stream lanes follow the native protocol and keep the default lane distinct" do
    create = %{"type" => "response.create", "model" => "gpt-6.2-sol"}

    for lane <- [nil, "task-1", "task_2.thread"] do
      request = if lane, do: Map.put(create, "stream_id", lane), else: create

      assert ModelRequest.websocket(@job, "codex", "work", Jason.encode!(request)) ==
               {:ok, %{kind: :create, lane: lane}}
    end

    for lane <- ["", nil, "has space", String.duplicate("x", 257)] do
      assert ModelRequest.websocket(
               @job,
               "codex",
               "work",
               Jason.encode!(Map.put(create, "stream_id", lane))
             ) == {:error, :model_target_refused}
    end
  end

  test "inference cannot outlive its tracked request as a provider background task" do
    for extra <- [%{}, %{"background" => false}, %{"background" => nil}] do
      body = Jason.encode!(Map.merge(%{"model" => "gpt-6.2-sol"}, extra))
      assert ModelRequest.validate(@job, "codex", "work", "/v1/responses", body) == :ok
    end

    for background <- [true, "true"] do
      body =
        Jason.encode!(%{
          "type" => "response.create",
          "model" => "gpt-6.2-sol",
          "background" => background
        })

      assert ModelRequest.validate(@job, "codex", "work", "/v1/responses", body) ==
               {:error, :model_target_refused}

      assert ModelRequest.websocket(@job, "codex", "work", body) ==
               {:error, :model_target_refused}
    end
  end
end
