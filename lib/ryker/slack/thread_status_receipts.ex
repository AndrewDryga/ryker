defmodule Ryker.Slack.ThreadStatusReceipts do
  @moduledoc "Append-only observations of actual Slack status API results, separate from desired state."
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Slack.{ThreadStatuses, ThreadStatusReceipt}

  def record(status, result) do
    %ThreadStatusReceipt{
      workspace_ref: status.workspace_ref,
      channel_ref: status.channel_ref,
      thread_ref: status.thread_ref,
      generation: status.generation,
      lease_ref: status.lease_ref,
      origin_kind: status.origin_kind,
      origin_id: status.origin_id,
      phase: Atom.to_string(status.phase),
      text: status.desired_text,
      acknowledged_at: if(result == :ok, do: DateTime.utc_now()),
      error:
        if(result != :ok, do: InspectionRedactor.artifact(inspect(result), max_bytes: 1_000).text)
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:lease_ref])
    |> tap(fn _receipt -> ThreadStatuses.broadcast_thread_status_updated(status) end)
  end

  def for_episode(episode_id) do
    episode_id
    |> ThreadStatusReceipt.Query.by_episode_id()
    |> ThreadStatusReceipt.Query.ordered_by_recent()
    |> ThreadStatusReceipt.Query.limit_to(500)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.chunk_by(&{&1.text, &1.error, &1.origin_kind, &1.origin_id})
    |> Enum.map(&hd/1)
  end
end
