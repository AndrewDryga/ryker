defmodule Ryker.Episodes.Reactions do
  @moduledoc """
  Records passive emoji feedback against one exact delivered Ryker message.

  A reaction is conversation context, not authorization and not a new model
  request. The provider adapter supplies authenticated actor and message
  identity; this boundary resolves that message back to its durable Work turn
  before appending an idempotent episode event.

  Every reaction on one of Ryker's messages is also feedback on the answer
  (`Ryker.Feedback`), recorded with the episode event in one transaction. A
  quick reply routing sent by itself, or an update the Work model posted, has
  no Work turn: a reaction on one is kept as feedback on its request alone
  (`Ryker.Feedback.Answers`), and it wakes nothing.
  """
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Event}
  alias Ryker.Feedback
  alias Ryker.Feedback.Answers
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Work.Turn
  require Logger

  @fields [:action, :actor_ref, :emoji_name, :event_ref, :occurred_at, :source, :target]
  @source_fields [:kind, :ref]
  @target_fields [:conversation_ref, :message_ref, :transport]
  @maximum_projected_events 400
  @maximum_model_state_events 400

  @type attributes :: %{
          action: :add | :remove,
          actor_ref: String.t(),
          emoji_name: String.t(),
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          source: %{kind: String.t(), ref: String.t()},
          target: %{
            conversation_ref: String.t(),
            message_ref: String.t(),
            transport: String.t()
          }
        }

  @doc """
  Records one reaction added to or taken back from one of Ryker's messages.

  On a Work reply it is the episode's event and feedback on the answer,
  returned as the episode's transition. On a quick reply or a posted update it
  is feedback alone, returned as `%{status: :applied | :duplicate}`. A message
  that is not one Ryker delivered is `:conversation_reaction_target_not_found`.
  """
  @spec record(attributes()) ::
          {:ok, Ryker.Episodes.Transition.t() | %{status: :applied | :duplicate}}
          | {:error, term()}
  def record(%{} = attributes) do
    with :ok <- exact_fields(attributes, @fields, :fields),
         :ok <- action(attributes.action),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- emoji(attributes.emoji_name),
         :ok <- reference(attributes.event_ref, :event_ref),
         :ok <- occurred_at(attributes.occurred_at),
         :ok <- source(attributes.source),
         :ok <- target(attributes.target),
         :ok <- source_matches_transport(attributes.source.kind, attributes.target.transport) do
      case resolve_target(attributes.target) do
        {:ok, episode, delivery_ref} -> record_on_reply(attributes, episode, delivery_ref)
        {:error, :conversation_reaction_target_not_found} -> record_on_other_message(attributes)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def record(_attributes), do: {:error, {:invalid_conversation_reaction, :fields}}

  defp record_on_reply(attributes, episode, delivery_ref) do
    command = %Command.RecordReaction{
      action: attributes.action,
      actor_ref: attributes.actor_ref,
      emoji_name: attributes.emoji_name,
      episode_key: episode.key,
      event_ref: attributes.event_ref,
      occurred_at: attributes.occurred_at,
      source: attributes.source,
      target_delivery_ref: delivery_ref,
      target_message_ref: attributes.target.message_ref
    }

    Repo.transaction(fn ->
      case Episodes.apply_batch_in_transaction([command]) do
        {:ok, [transition]} ->
          keep_feedback(attributes, {:episode, transition.episode.id})
          transition

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # The reaction is the event; the feedback is what it says about the answer.
  # A signal that cannot be kept is logged and never refuses the reaction.
  defp keep_feedback(attributes, request) do
    case Feedback.record_in_transaction(feedback(attributes, request)) do
      {:ok, _recorded} ->
        :ok

      {:error, reason} ->
        Logger.warning("reaction feedback not kept: #{inspect(reason, limit: 5)}")
    end
  end

  defp record_on_other_message(attributes) do
    with {:ok, request} <- Answers.message_request(attributes.target),
         {:ok, %{status: status}} <- Feedback.record(feedback(attributes, request)) do
      {:ok, %{status: if(status == :recorded, do: :applied, else: :duplicate)}}
    else
      :error -> {:error, :conversation_reaction_target_not_found}
      {:error, :feedback_request_not_found} -> {:error, :conversation_reaction_target_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp feedback(attributes, request) do
    %{
      kind: if(attributes.action == :add, do: :reaction_added, else: :reaction_removed),
      value: attributes.emoji_name,
      actor_ref: attributes.actor_ref,
      source: attributes.source.kind,
      source_ref: attributes.event_ref,
      occurred_at: attributes.occurred_at,
      message_ref: attributes.target.message_ref,
      request: request
    }
  end

  @doc """
  Returns current added reactions, grouped by host delivery reference.

  Add/remove events are reduced in durable sequence order. The result is a
  bounded projection for platform UIs; the immutable events remain the source
  of truth.
  """
  @spec current_for_episodes([Ecto.UUID.t()]) :: %{optional(String.t()) => [map()]}
  def current_for_episodes([]), do: %{}

  def current_for_episodes(episode_ids) when is_list(episode_ids) do
    episode_ids
    |> reaction_events()
    |> Enum.reduce(%{}, &apply_current_event/2)
    |> Map.values()
    |> Enum.group_by(
      & &1.target_delivery_ref,
      &Map.take(&1, [:actor_ref, :emoji_name, :occurred_at])
    )
    |> Map.new(fn {delivery_ref, reactions} ->
      {delivery_ref, Enum.sort_by(reactions, &{&1.emoji_name, &1.actor_ref})}
    end)
  end

  def current_for_episodes(_episode_ids), do: %{}

  @doc false
  @spec model_context(Ecto.UUID.t(), pos_integer(), pos_integer()) :: map()
  def model_context(episode_id, next_sequence, event_limit \\ 40)

  def model_context(episode_id, next_sequence, event_limit)
      when is_binary(episode_id) and is_integer(next_sequence) and next_sequence > 0 and
             is_integer(event_limit) and event_limit in 1..100 do
    rows = model_event_rows(episode_id, next_sequence, @maximum_model_state_events)

    %{
      "current" => current_model_documents(rows),
      "events" => rows |> Enum.take(-event_limit) |> Enum.map(&model_event_document/1)
    }
  end

  def model_context(_episode_id, _next_sequence, _event_limit),
    do: %{"current" => [], "events" => []}

  defp model_event_rows(episode_id, next_sequence, limit) do
    episode_id |> Event.Query.reactions_before(next_sequence, limit) |> Repo.all()
  end

  defp model_event_document(event) do
    Map.take(event.payload, [
      "action",
      "actor_ref",
      "emoji_name",
      "occurred_at",
      "target_delivery_ref",
      "target_message_ref"
    ])
  end

  defp current_model_documents(rows) do
    rows
    |> Enum.reduce(%{}, &apply_model_event/2)
    |> Map.values()
    |> Enum.group_by(&{&1.target_delivery_ref, &1.target_message_ref, &1.emoji_name})
    |> Enum.map(fn {{delivery_ref, message_ref, emoji_name}, reactions} ->
      %{
        "actor_refs" => reactions |> Enum.map(& &1.actor_ref) |> Enum.sort(),
        "count" => length(reactions),
        "emoji_name" => emoji_name,
        "target_delivery_ref" => delivery_ref,
        "target_message_ref" => message_ref
      }
    end)
    |> Enum.sort_by(&{&1["target_delivery_ref"], &1["target_message_ref"], &1["emoji_name"]})
  end

  defp apply_model_event(
         %{
           payload: %{
             "action" => action,
             "actor_ref" => actor_ref,
             "emoji_name" => emoji_name,
             "target_delivery_ref" => delivery_ref,
             "target_message_ref" => message_ref
           }
         },
         current
       )
       when action in ["add", "remove"] do
    key = {delivery_ref, actor_ref, emoji_name}

    if action == "add" do
      Map.put(current, key, %{
        actor_ref: actor_ref,
        emoji_name: emoji_name,
        target_delivery_ref: delivery_ref,
        target_message_ref: message_ref
      })
    else
      Map.delete(current, key)
    end
  end

  defp apply_model_event(_invalid, current), do: current

  defp resolve_target(target) do
    candidates = target |> Turn.Query.delivered_as() |> Repo.all()

    case candidates do
      [] ->
        {:error, :conversation_reaction_target_not_found}

      [{episode, delivery_ref} | rest] ->
        if Enum.all?(rest, fn {other, _ref} -> other.id == episode.id end),
          do: {:ok, episode, delivery_ref},
          else: {:error, :conversation_reaction_target_ambiguous}
    end
  end

  defp reaction_events(episode_ids) do
    episode_ids
    |> Event.Query.recent_reactions(@maximum_projected_events)
    |> Repo.all()
  end

  defp apply_current_event(
         %{
           occurred_at: occurred_at,
           payload: %{
             "action" => action,
             "actor_ref" => actor_ref,
             "emoji_name" => emoji_name,
             "target_delivery_ref" => target_delivery_ref
           }
         },
         current
       )
       when action in ["add", "remove"] and is_binary(actor_ref) and is_binary(emoji_name) and
              is_binary(target_delivery_ref) do
    key = {target_delivery_ref, actor_ref, emoji_name}

    if action == "add" do
      Map.put(current, key, %{
        actor_ref: actor_ref,
        emoji_name: emoji_name,
        occurred_at: occurred_at,
        target_delivery_ref: target_delivery_ref
      })
    else
      Map.delete(current, key)
    end
  end

  defp apply_current_event(_invalid, current), do: current

  defp exact_fields(map, fields, field) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(fields),
      do: :ok,
      else: {:error, {:invalid_conversation_reaction, field}}
  end

  defp action(value) when value in [:add, :remove], do: :ok
  defp action(_value), do: {:error, {:invalid_conversation_reaction, :action}}

  defp emoji(value) do
    if is_binary(value) and byte_size(value) <= 100 and
         Regex.match?(~r/\A[a-z0-9_+\-]+\z/, value),
       do: :ok,
       else: {:error, {:invalid_conversation_reaction, :emoji_name}}
  end

  defp occurred_at(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: :ok
  defp occurred_at(_value), do: {:error, {:invalid_conversation_reaction, :occurred_at}}

  defp source(%{} = source) do
    with :ok <- exact_fields(source, @source_fields, :source),
         :ok <- reference(source.kind, :source) do
      reference(source.ref, :source)
    end
  end

  defp source(_source), do: {:error, {:invalid_conversation_reaction, :source}}

  defp target(%{} = target) do
    with :ok <- exact_fields(target, @target_fields, :target),
         :ok <- reference(target.transport, :target),
         :ok <- reference(target.conversation_ref, :target) do
      reference(target.message_ref, :target)
    end
  end

  defp target(_target), do: {:error, {:invalid_conversation_reaction, :target}}

  defp source_matches_transport("control_plane", "control_plane"), do: :ok
  defp source_matches_transport("slack", "slack"), do: :ok

  defp source_matches_transport(_source, _transport),
    do: {:error, {:invalid_conversation_reaction, :transport}}

  defp reference(value, field),
    do: Reference.check(value, field, :invalid_conversation_reaction)
end
