defmodule Ryker.Slack.Mentions do
  @moduledoc """
  Validates and renders the small typed Slack-entity syntax accepted in final prose.

  Raw Slack control syntax is always escaped. Only a typed link whose opaque ref
  appears in the host-built authority snapshot becomes a native Slack mention or
  channel link.
  """
  import Ryker.Slack.Renderer.Blocks, only: [escape: 1]
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Repo
  alias Ryker.Slack.Id

  @typed_link ~r/\[([^\]\r\n]{1,120})\]\((slack-(?:user|channel|usergroup|broadcast)):([A-Za-z0-9_.:-]{1,1024})\)/u
  @typed_prefix ~r/\]\(\s*slack-/u
  @maximum_mentions 32
  @maximum_markdown_characters 12_000
  @authority_fields ~w(broadcasts channels user_groups users workspace_ref)

  @spec typed?(term()) :: boolean()
  def typed?(message) when is_binary(message), do: Regex.match?(@typed_prefix, message)
  def typed?(_message), do: false

  @spec authority(Episodes.Episode.t()) :: map() | nil
  def authority(%Episodes.Episode{active_input_refs: active_refs} = episode),
    do: authority(episode, active_refs)

  # Whom a message may name, from the inputs it answers.
  defp authority(
         %Episodes.Episode{
           destination_conversation_ref: "slack:" <> _rest = conversation_ref,
           destination_transport: "slack",
           id: episode_id
         },
         input_refs
       ) do
    case conversation(conversation_ref) do
      {:ok, workspace_ref, _channel_ref} ->
        authority_from_events(
          workspace_ref,
          conversation_ref,
          active_events(episode_id, input_refs)
        )

      {:error, _reason} ->
        nil
    end
  end

  defp authority(%Episodes.Episode{}, _input_refs), do: nil

  @doc """
  Resolves the Slack mention authority for one immutable delivery intent: a
  Work answer, or a Work update posted before it, which may name exactly whom
  the answer may.

  The delivery reference is host-owned and unique. Platform publishers use
  this lookup instead of accepting mention authority from model output or a
  transport payload.

  An answer names whom the inputs its turn answered may: accepting it clears
  the episode's active inputs, and working authority out from those again
  refused a final reply that named the person who asked (2026-10-04 review).
  An update posted while the turn works answers the episode's active inputs.
  """
  @spec authority_for_delivery(String.t()) :: {:ok, map()} | {:error, term()}
  def authority_for_delivery(delivery_ref)
      when is_binary(delivery_ref) and byte_size(delivery_ref) in 1..256 do
    answered =
      Repo.one(Episodes.Episode.Query.answered_by_delivery(delivery_ref)) ||
        Repo.one(Episodes.Episode.Query.updated_by_slack_action(delivery_ref))

    case answered do
      {%Episodes.Episode{} = episode, input_refs} ->
        case authority(episode, input_refs || []) do
          %{} = authority -> {:ok, authority}
          nil -> {:error, {:slack_mention_authority_unavailable, :episode}}
        end

      nil ->
        {:error, {:slack_mention_authority_unavailable, :delivery}}
    end
  end

  def authority_for_delivery(_delivery_ref),
    do: {:error, {:slack_mention_authority_unavailable, :delivery}}

  @spec authority_from_events(String.t(), String.t(), [Episodes.Event.t() | map()]) :: map()
  defp authority_from_events(workspace_ref, conversation_ref, events)
       when is_binary(workspace_ref) and is_binary(conversation_ref) and is_list(events) do
    evidence = Enum.map_join(events, "\n", &event_evidence/1)

    users =
      events
      |> Enum.flat_map(&event_actor/1)
      |> Kernel.++(captures(evidence, ~r/<@([A-Z0-9]+)>/, "slack-user:"))
      |> Kernel.++(captures(evidence, ~r/slack-user:([A-Z0-9]+)/, "slack-user:"))

    channels =
      [conversation_ref | captures(evidence, ~r/(slack:[A-Z0-9]+:[A-Z0-9]+)/, "")]
      |> Enum.filter(&match?({:ok, ^workspace_ref, _channel_ref}, conversation(&1)))

    user_groups =
      captures(evidence, ~r/<!subteam\^([A-Z0-9]+)(?:\|[^>]+)?>/, "slack-usergroup:") ++
        captures(evidence, ~r/slack-usergroup:([A-Z0-9]+)/, "slack-usergroup:")

    broadcasts =
      captures(evidence, ~r/<!((?:here|channel|everyone))>/, "") ++
        captures(evidence, ~r/slack-broadcast:(here|channel|everyone)/, "")

    %{
      "broadcasts" => unique(broadcasts),
      "channels" => unique(channels),
      "user_groups" => unique(user_groups),
      "users" => unique(users),
      "workspace_ref" => workspace_ref
    }
  end

  @spec prepare_authority(term()) :: {:ok, map() | nil} | {:error, term()}
  def prepare_authority(nil), do: {:ok, nil}

  def prepare_authority(%{} = authority) do
    with true <- Maps.exact_keys?(authority, @authority_fields),
         :ok <- slack_id(authority["workspace_ref"]),
         {:ok, users} <- refs(authority["users"], "slack-user", 256),
         {:ok, channels} <- channel_refs(authority["channels"], authority["workspace_ref"]),
         {:ok, user_groups} <- refs(authority["user_groups"], "slack-usergroup", 256),
         {:ok, broadcasts} <- broadcasts(authority["broadcasts"]) do
      {:ok,
       %{
         broadcasts: MapSet.new(broadcasts),
         channels: MapSet.new(channels),
         user_groups: MapSet.new(user_groups),
         users: MapSet.new(users),
         workspace_ref: authority["workspace_ref"]
       }}
    else
      _invalid -> {:error, {:invalid_slack_mention_authority, :fields}}
    end
  end

  def prepare_authority(_authority),
    do: {:error, {:invalid_slack_mention_authority, :fields}}

  @spec violations(String.t(), map() | nil) :: [String.t()]
  def violations(message, authority) when is_binary(message) do
    case prepare_authority(authority) do
      {:ok, prepared} -> do_violations(message, prepared)
      {:error, _reason} -> ["Remove typed Slack entities from this reply."]
    end
  end

  def violations(_message, _authority),
    do: ["Remove malformed typed Slack entities from this reply."]

  @spec render(String.t(), map() | nil) :: {:ok, String.t()} | {:error, term()}
  def render(message, authority) when is_binary(message) do
    with {:ok, prepared} <- prepare_authority(authority),
         [] <- do_violations(message, prepared),
         {:ok, rendered} <- render_matches(message, prepared) do
      {:ok, rendered}
    else
      [_first | _rest] -> {:error, {:invalid_slack_mentions, :unauthorized}}
      {:error, reason} -> {:error, reason}
    end
  end

  def render(_message, _authority), do: {:error, {:invalid_slack_mentions, :message}}

  defp do_violations(message, nil) do
    if typed?(message),
      do: ["Remove typed Slack entities from this non-Slack reply."],
      else: []
  end

  defp do_violations(message, authority) do
    matches = Regex.scan(@typed_link, message)
    stripped = Regex.replace(@typed_link, message, "")

    checks = [
      {matches != [] and String.length(message) > @maximum_markdown_characters,
       "Keep a reply containing native Slack entities at or below 12,000 characters."},
      {length(matches) > @maximum_mentions,
       "Use at most #{@maximum_mentions} typed Slack entities in one reply."},
      {Regex.match?(@typed_prefix, stripped),
       "Fix the malformed typed Slack entity link before replying."}
    ]

    unauthorized =
      matches
      |> Enum.flat_map(fn [_whole, _label, scheme, target] ->
        case native_entity(scheme, target, authority) do
          {:ok, _native} -> []
          {:error, _reason} -> ["The typed Slack entity #{scheme}:#{target} is not authorized."]
        end
      end)
      |> Enum.uniq()

    violations = for {true, violation} <- checks, do: violation
    violations ++ unauthorized
  end

  defp render_matches(message, nil), do: {:ok, escape(message)}

  defp render_matches(message, authority) do
    matches = Regex.scan(@typed_link, message, return: :index)

    matches
    |> Enum.reduce_while({:ok, [], 0}, fn
      [{start, length}, _label, {scheme_start, scheme_length}, {target_start, target_length}],
      {:ok, rendered, cursor} ->
        before = binary_part(message, cursor, start - cursor)
        scheme = binary_part(message, scheme_start, scheme_length)
        target = binary_part(message, target_start, target_length)

        case native_entity(scheme, target, authority) do
          {:ok, native} ->
            {:cont, {:ok, [rendered, escape(before), native], start + length}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
    |> case do
      {:ok, rendered, cursor} ->
        tail = binary_part(message, cursor, byte_size(message) - cursor)
        {:ok, IO.iodata_to_binary([rendered, escape(tail)])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp native_entity("slack-user", target, authority) do
    ref = "slack-user:" <> target

    if slack_id(target) == :ok and MapSet.member?(authority.users, ref),
      do: {:ok, "<@#{target}>"},
      else: {:error, :unauthorized}
  end

  defp native_entity("slack-channel", target, authority) do
    with true <- MapSet.member?(authority.channels, target),
         {:ok, workspace_ref, channel_ref} <- conversation(target),
         true <- workspace_ref == authority.workspace_ref do
      {:ok, "<##{channel_ref}>"}
    else
      _invalid -> {:error, :unauthorized}
    end
  end

  defp native_entity("slack-usergroup", target, authority) do
    ref = "slack-usergroup:" <> target

    if slack_id(target) == :ok and MapSet.member?(authority.user_groups, ref),
      do: {:ok, "<!subteam^#{target}>"},
      else: {:error, :unauthorized}
  end

  defp native_entity("slack-broadcast", target, authority) do
    if target in ["here", "channel", "everyone"] and
         MapSet.member?(authority.broadcasts, target),
       do: {:ok, "<!#{target}>"},
       else: {:error, :unauthorized}
  end

  defp native_entity(_scheme, _target, _authority), do: {:error, :unauthorized}

  defp refs(values, prefix, maximum) when is_list(values) and length(values) <= maximum do
    expected = prefix <> ":"

    if values == Enum.uniq(values) and Enum.all?(values, &typed_ref?(&1, expected)),
      do: {:ok, values},
      else: {:error, :refs}
  end

  defp refs(_values, _prefix, _maximum), do: {:error, :refs}

  defp typed_ref?(value, expected) when is_binary(value) do
    String.starts_with?(value, expected) and
      value
      |> binary_part(byte_size(expected), byte_size(value) - byte_size(expected))
      |> slack_id()
      |> Kernel.==(:ok)
  end

  defp typed_ref?(_value, _expected), do: false

  defp channel_refs(values, workspace_ref) when is_list(values) and length(values) <= 256 do
    if values == Enum.uniq(values) and
         Enum.all?(values, &match?({:ok, ^workspace_ref, _channel_ref}, conversation(&1))),
       do: {:ok, values},
       else: {:error, :channels}
  end

  defp channel_refs(_values, _workspace_ref), do: {:error, :channels}

  defp broadcasts(values) when is_list(values) and length(values) <= 3 do
    if values == Enum.uniq(values) and Enum.all?(values, &(&1 in ["here", "channel", "everyone"])),
      do: {:ok, values},
      else: {:error, :broadcasts}
  end

  defp broadcasts(_values), do: {:error, :broadcasts}

  defp conversation(value) when is_binary(value) do
    case ConversationRef.parse_slack(value) do
      {:ok, workspace_ref, channel_ref} ->
        with :ok <- slack_id(workspace_ref), :ok <- slack_id(channel_ref) do
          {:ok, workspace_ref, channel_ref}
        end

      :error ->
        {:error, :conversation}
    end
  end

  defp conversation(_value), do: {:error, :conversation}

  defp event_actor(%Episodes.Event{payload: payload}), do: event_actor(payload)

  defp event_actor(%{"actor_ref" => "slack:user:" <> user_ref}) do
    if slack_id(user_ref) == :ok, do: ["slack-user:" <> user_ref], else: []
  end

  defp event_actor(_event), do: []

  defp active_events(_episode_id, []), do: []

  defp active_events(episode_id, active_refs) do
    episode_id
    |> Episodes.Event.Query.by_episode_id()
    |> Episodes.Event.Query.admitted_inputs(Enum.uniq(active_refs))
    |> Episodes.Event.Query.ordered_by_sequence()
    |> Repo.all()
  end

  # Evidence is scanned for mention tokens, so key order is irrelevant. An
  # event without admitted content, or content JSON cannot carry, is no
  # evidence; a host error here is not swallowed into "no evidence".
  defp event_evidence(%Episodes.Event{payload: %{"payload" => %{"content" => content}}}) do
    case Jason.encode(content) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> ""
    end
  end

  defp event_evidence(_event), do: ""

  defp captures(text, regex, prefix) do
    regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [value] -> prefix <> value end)
  end

  defp unique(values), do: values |> Enum.uniq() |> Enum.sort()

  defp slack_id(value) do
    if Id.valid?(value),
      do: :ok,
      else: {:error, :slack_id}
  end
end
