defmodule Ryker.Fixtures.StatusConfirmations do
  @moduledoc """
  Host status custody around harvested wording and structural kind, status,
  revision and preference-enum permutations, not a model automation decision.
  """
  alias Ryker.Behaviors.Behavior
  alias Ryker.Fixtures.{Personalization, SavedEntities}
  alias Ryker.Repo
  alias Ryker.Schedules.Schedule

  def current!(kind, status) do
    corpus =
      File.read!("testdata/learning/retained-people-about-themselves.json") |> Jason.decode!()

    [first, second | _] = Jason.decode!(corpus["recorded_result"]["result"])["people"]
    workspace = "TSTATUSCONFIRM#{System.unique_integer([:positive])}"
    source = SavedEntities.source!("slack:#{workspace}:C1")
    entity = entity!(source, kind, first["fact"], status)
    %{entity: entity, kind: kind, replacement: second["fact"], source: source}
  end

  def edit!(%{entity: %Schedule{} = schedule, replacement: wording}) do
    attributes = %{revision: schedule.revision + 1, task: wording, title: wording}
    schedule |> Schedule.Changeset.update(attributes) |> Repo.update!()
  end

  def edit!(%{entity: %Behavior{} = behavior, replacement: wording}) do
    payload = replacement(behavior, wording)
    attributes = %{payload: payload, revision: behavior.revision + 1}
    behavior |> Behavior.Changeset.update(attributes) |> Repo.update!()
  end

  def edit!(_context), do: raise(ArgumentError, "unsupported status confirmation entity")

  def fetch!(context), do: Repo.get!(context.entity.__struct__, context.entity.id)

  def cleanup!(%{entity: %Schedule{} = schedule, source: source}) do
    Repo.delete_all(Schedule.Query.by_ref(schedule.ref))
    Personalization.cleanup!(source)
  end

  def cleanup!(%{entity: %Behavior{}, source: source}), do: Personalization.cleanup!(source)

  def cleanup!(_context), do: raise(ArgumentError, "unsupported status confirmation entity")

  defp entity!(source, :schedule, wording, status),
    do: SavedEntities.schedule!(source, wording, 1, status: status)

  defp entity!(source, kind, wording, status) do
    payload = payload(kind, wording, source.conversation_ref)

    SavedEntities.behavior!(source, kind, payload,
      scope_ref: source.conversation_ref,
      status: status
    )
  end

  defp payload(:guidance, wording, _conversation) do
    %{
      "expires_in" => "30d",
      "repository" => nil,
      "scope" => "conversation",
      "subject" => wording,
      "summary" => wording,
      "text" => wording,
      "visibility" => "conversation"
    }
  end

  defp payload(:preference, _wording, _conversation) do
    %{
      "expires_in" => "30d",
      "key" => "response_detail",
      "repository" => nil,
      "scope" => "conversation",
      "value" => "detailed"
    }
  end

  defp payload(:standing_assignment, wording, conversation) do
    %{
      "context_channel" => conversation,
      "delivery_channel" => conversation,
      "expires_at" => nil,
      "filter" => %{},
      "hold" => nil,
      "repository" => nil,
      "source_kind" => "slack",
      "task" => wording,
      "title" => wording
    }
  end

  defp replacement(%Behavior{kind: :guidance, payload: payload}, wording),
    do: Map.merge(payload, %{"subject" => wording, "summary" => wording, "text" => wording})

  defp replacement(%Behavior{kind: :preference, payload: payload}, _wording),
    do: Map.put(payload, "value", "concise")

  defp replacement(%Behavior{kind: :standing_assignment, payload: payload}, wording),
    do: Map.merge(payload, %{"task" => wording, "title" => wording})

  defp replacement(_behavior, _wording),
    do: raise(ArgumentError, "unsupported status confirmation behavior")
end
