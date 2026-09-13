defmodule Ryker.Episodes.Snapshot do
  @moduledoc """
  Stable data-only projection used by replay fixtures and external boundaries.
  """

  alias Ryker.Episodes.Episode

  @spec from_episode(Episode.t()) :: map()
  def from_episode(%Episode{} = episode) do
    %{
      "active_inputs" => episode.active_input_refs,
      "destination" => %{
        "conversation_ref" => episode.destination_conversation_ref,
        "thread_ref" => episode.destination_thread_ref,
        "transport" => episode.destination_transport
      },
      "episode_key" => episode.key,
      "input_revisions" => episode.input_revisions,
      "linked_episode_id" => episode.linked_episode_id,
      "owner" => owner(episode),
      "queued_inputs" => episode.queued_input_refs,
      "semantic_version" => episode.semantic_version,
      "state" => Atom.to_string(episode.state)
    }
  end

  defp owner(%Episode{owner_kind: nil, owner_ref: nil}), do: nil

  defp owner(%Episode{owner_kind: :event} = episode) do
    %{
      "deadline_at" =>
        if(episode.owner_deadline_at, do: DateTime.to_iso8601(episode.owner_deadline_at)),
      "kind" => "event",
      "ref" => episode.owner_ref
    }
  end

  defp owner(%Episode{} = episode) do
    %{"kind" => Atom.to_string(episode.owner_kind), "ref" => episode.owner_ref}
  end
end
