defmodule Ryker.LocalRouting.WorkerTest do
  use Ryker.DataCase, async: false
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Observations
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.{Comparison, Worker}
  alias Ryker.PollingWorker
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.UTCDateTime

  # 2026-09-27: every lane crashed live on a due time Postgres computed as a
  # minimum, which comes back without a zone. The comparison lane sleeps until
  # its next retry the same way, so its due time must come back as UTC.
  test "an idle comparison lane sleeps until its next retry, read as UTC" do
    entry = entry!()
    {:ok, due} = DateTime.utc_now() |> DateTime.add(30) |> DateTime.truncate(:second) |> exact()
    retry!(entry, due)

    assert %DateTime{time_zone: "Etc/UTC"} = found = LocalRouting.next_due_at(DateTime.utc_now())
    assert DateTime.compare(found, due) == :eq

    delay = PollingWorker.idle_delay(&LocalRouting.next_due_at/1, 60_000)
    assert delay in 28_000..30_000
  end

  test "the lane starts only on an endpoint and a model the settings would save" do
    assert %{endpoint: "http://host.docker.internal:11434/v1", model: "qwen2.5:3b"} =
             Worker.options!(configuration())

    assert_raise ArgumentError, ~r/https/, fn ->
      Worker.options!(%{configuration() | endpoint: "http://llm.example.com/v1"})
    end

    assert_raise ArgumentError, ~r/model/, fn ->
      Worker.options!(%{configuration() | model: "two words"})
    end

    assert_raise ArgumentError, ~r/timeout/, fn ->
      Worker.options!(%{configuration() | timeout_ms: 0})
    end
  end

  defp exact(at), do: UTCDateTime.exact(at)

  defp configuration do
    %{
      endpoint: "http://host.docker.internal:11434/v1",
      model: "qwen2.5:3b",
      max_attempts: 4,
      poll_interval_ms: 1_000,
      retry_base_seconds: 30,
      retry_max_seconds: 600,
      timeout_ms: 120_000
    }
  end

  defp entry! do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "hi"},
        event_kind: :message,
        event_ref: "Ev-local-worker",
        message_ref: "1787832001.000100",
        occurred_at: ~U[2026-09-27 10:00:00.000000Z],
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TE5D7C8842D32"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp retry!(entry, due) do
    now = DateTime.utc_now()

    Repo.insert!(%Comparison{
      input_id: entry.id,
      source_identity: Observations.source_identity(entry),
      generation: 1,
      execution_mode: :live,
      status: :pending,
      attempt_count: 1,
      next_attempt_at: due,
      last_error: "could not reach the local model: connection refused",
      local_model: "qwen2.5:3b",
      inserted_at: now,
      updated_at: now
    })
  end
end
