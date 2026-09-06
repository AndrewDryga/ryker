defmodule Responder.Slack.ThreadStatusReceipts do
  @moduledoc "Append-only observations of actual Slack status API results, separate from desired state."
  use Ecto.Schema
  import Ecto.Query
  alias Responder.ControlPlane.InspectionRedactor
  alias Responder.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "slack_thread_status_receipts" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:thread_ref, :string)
    field(:generation, :integer)
    field(:lease_ref, :binary_id)
    field(:origin_kind, :string)
    field(:origin_id, :binary_id)
    field(:phase, :string)
    field(:text, :string)
    field(:error, :string)
    field(:acknowledged_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def record(status, result) do
    %__MODULE__{
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
  end

  def for_thread(workspace, channel, thread) do
    Repo.all(
      from(r in __MODULE__,
        where:
          r.workspace_ref == ^workspace and r.channel_ref == ^channel and r.thread_ref == ^thread,
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1_000
      )
    )
  end

  def for_episode(episode_id) do
    inputs =
      from(i in Responder.Ingress.Inbox.Entry, where: i.episode_id == ^episode_id, select: i.id)

    Repo.all(
      from(r in __MODULE__,
        where:
          (r.origin_kind == "episode" and r.origin_id == ^episode_id) or
            (r.origin_kind == "input" and r.origin_id in subquery(inputs)),
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 500
      )
    )
    |> Enum.reverse()
    |> Enum.chunk_by(&{&1.text, &1.error, &1.origin_kind, &1.origin_id})
    |> Enum.map(&hd/1)
  end
end
