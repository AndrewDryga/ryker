defmodule Ryker.Ingress.Inbox.RoutingBatch do
  @moduledoc "Bounds the wait for ordinary human Slack messages before routing can claim them."
  alias Ryker.CanonicalJSON
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  @quiet_seconds 2
  @maximum_seconds 8
  @maximum_inputs 8
  @maximum_bytes 24 * 1_024

  # The caller owns the source conversation lock. Lock the members as well:
  # an executor may claim the first message while the next receipt arrives.
  def attributes(_input, %{engagement_receipt: %{"path" => "slack_shortcut"}}, _id, _now), do: %{}

  def attributes(
        %{
          source: %{kind: "slack"},
          destination: %{thread_ref: thread},
          actor: %{kind: :user},
          event_kind: :message,
          content: content
        } = input,
        %{slack_addressing: %{audience: audience}, execution_mode: mode},
        id,
        now
      )
      when is_binary(thread) and not is_nil(audience) do
    bytes = CanonicalJSON.encoded_size(content)

    if eligible?(content, bytes) do
      ref = input |> Entry.Query.last_for_routing_batch(mode) |> Repo.one()
      entries = members(ref)
      deadline = DateTime.add(now, @quiet_seconds, :second)

      with %Entry{} = first <- Enum.find(entries, &(&1.id == ref)),
           true <- open?(entries, bytes, now) do
        extend(first, deadline)
      else
        _closed -> %{routing_batch_ref: id, next_attempt_at: deadline}
      end
    else
      %{}
    end
  end

  def attributes(_input, _settings, _id, _now), do: %{}

  defp eligible?(content, bytes) do
    bytes <= @maximum_bytes and is_binary(content["text"]) and
      is_nil(content["subtype"]) and is_nil(content["interaction_kind"]) and
      Map.get(content, "files", []) == [] and Map.get(content, "attachments", []) == []
  end

  defp extend(first, deadline) do
    due =
      Enum.min([deadline, DateTime.add(first.inserted_at, @maximum_seconds, :second)], DateTime)

    Repo.update_all(Entry.Query.by_routing_batch(first.id), set: [next_attempt_at: due])
    %{routing_batch_ref: first.id, next_attempt_at: due}
  end

  defp members(nil), do: []

  defp members(ref),
    do: ref |> Entry.Query.by_routing_batch() |> Entry.Query.lock_for_update() |> Repo.all()

  defp open?(entries, bytes, now) do
    length(entries) < @maximum_inputs and Enum.all?(entries, &unclaimed?(&1, now)) and
      bytes + Enum.sum_by(entries, &CanonicalJSON.encoded_size(&1.content)) <= @maximum_bytes
  end

  defp unclaimed?(
         %Entry{status: :pending, attempt_count: 0, next_attempt_at: %DateTime{} = due},
         now
       ),
       do: DateTime.after?(due, now)

  defp unclaimed?(_entry, _now), do: false
end
