defmodule Responder.Episodes.Reactions do
  @moduledoc """
  Records passive emoji feedback against one exact delivered Responder message.

  A reaction is conversation context, not authorization and not a new model
  request. The provider adapter supplies authenticated actor and message
  identity; this boundary resolves that message back to its durable Work turn
  before appending an idempotent episode event.
  """

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Event}
  alias Responder.Repo
  alias Responder.Work.Turn

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

  @spec record(attributes()) :: {:ok, Responder.Episodes.Transition.t()} | {:error, term()}
  def record(%{} = attributes) do
    with :ok <- exact_fields(attributes, @fields, :fields),
         :ok <- action(attributes.action),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- emoji(attributes.emoji_name),
         :ok <- reference(attributes.event_ref, :event_ref),
         :ok <- occurred_at(attributes.occurred_at),
         :ok <- source(attributes.source),
         :ok <- target(attributes.target),
         :ok <- source_matches_transport(attributes.source.kind, attributes.target.transport),
         {:ok, episode, delivery_ref} <- resolve_target(attributes.target) do
      Episodes.apply(%Command.RecordReaction{
        action: attributes.action,
        actor_ref: attributes.actor_ref,
        emoji_name: attributes.emoji_name,
        episode_key: episode.key,
        event_ref: attributes.event_ref,
        occurred_at: attributes.occurred_at,
        source: attributes.source,
        target_delivery_ref: delivery_ref,
        target_message_ref: attributes.target.message_ref
      })
    end
  end

  def record(_attributes), do: {:error, {:invalid_conversation_reaction, :fields}}

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
    |> Enum.group_by(& &1.target_delivery_ref, fn reaction ->
      Map.take(reaction, [:actor_ref, :emoji_name, :occurred_at])
    end)
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
    latest =
      from(event in Event,
        where:
          event.episode_id == ^episode_id and event.kind == :reaction_recorded and
            event.sequence < ^next_sequence,
        order_by: [desc: event.sequence],
        limit: ^limit,
        select: %{payload: event.payload, sequence: event.sequence}
      )

    Repo.all(from(event in subquery(latest), order_by: event.sequence))
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
    candidates =
      Repo.all(
        from(turn in Turn,
          join: episode in Episode,
          on: episode.id == turn.episode_id,
          where:
            turn.status == :settled and not is_nil(turn.delivered_at) and
              not is_nil(turn.external_receipt) and
              fragment("(?::jsonb)->>'transport' = ?", turn.external_receipt, ^target.transport) and
              fragment(
                "(?::jsonb)->>'conversation_ref' = ?",
                turn.external_receipt,
                ^target.conversation_ref
              ) and
              fragment(
                "(?::jsonb)->>'message_ref' = ?",
                turn.external_receipt,
                ^target.message_ref
              ),
          order_by: [desc: turn.delivered_at, desc: turn.id],
          limit: 8,
          select: {episode, turn.delivery_ref}
        )
      )

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
    latest =
      from(event in Event,
        where: event.episode_id in ^episode_ids and event.kind == :reaction_recorded,
        order_by: [desc: event.inserted_at, desc: event.id],
        limit: @maximum_projected_events,
        select: %{
          episode_id: event.episode_id,
          id: event.id,
          inserted_at: event.inserted_at,
          occurred_at: event.occurred_at,
          payload: event.payload,
          sequence: event.sequence
        }
      )

    Repo.all(
      from(event in subquery(latest),
        order_by: [asc: event.inserted_at, asc: event.id]
      )
    )
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

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_conversation_reaction, field}}
  end
end
