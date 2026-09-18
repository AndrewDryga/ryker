defmodule Ryker.Slack.Renderer.SavedEntityCard do
  @moduledoc """
  One detail projection for every saved or updated entity: schedules, standing
  rules, preferences, guidance and memories share it, on their own message and
  on the confirmed offer that created them.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  @saved_entity_kinds ~w(schedule standing_rule preference guidance memory)
  @saved_entity_statuses ~w(active paused disabled completed expired deleted superseded)

  @spec blocks(map()) :: [map()]
  def blocks(entity) do
    title = "*#{escape(entity["title"])}*"

    body =
      case entity["instructions"] do
        nil -> title
        instructions -> "#{title}\n#{escape(instructions)}"
      end

    [section(body), fact_fields(Enum.map(entity["facts"], &List.to_tuple/1))] ++
      [context(provenance(entity))] ++ controls(entity)
  end

  @spec text(map()) :: String.t()
  def text(entity) do
    facts =
      Enum.map_join(entity["facts"], "\n", fn [label, value] ->
        "#{heading(label)}: #{fact_text(value)}"
      end)

    "#{escape(entity["notice"])}: #{escape(entity["title"])}\n" <>
      "#{escape(entity["instructions"] || "")}\n#{facts}"
  end

  defp provenance(entity) do
    saved_by =
      case entity["saved_by"] do
        "slack:user:" <> user_ref -> "saved by #{mention(user_ref)}"
        other -> "saved by `#{escape(other)}`"
      end

    "#{escape(entity["notice"])} · #{saved_by} · #{display_time(entity["saved_at"])}"
  end

  defp controls(%{"removable" => false}), do: []

  defp controls(%{"kind" => "memory", "ref" => ref, "title" => title}) do
    [
      actions("#{ref}:controls", [
        button(
          "ryker_forget_memory",
          "Forget memory",
          ref,
          "danger",
          "Forget this memory?",
          "I'll stop recalling “#{title}”. Messages I already sent and the original conversation stay as they are.",
          "Forget memory"
        )
      ])
    ]
  end

  defp controls(
         %{
           "kind" => kind,
           "ref" => ref,
           "revision" => revision,
           "title" => title
         } = entity
       ) do
    {label, action_id, value, consequence} =
      case kind do
        "schedule" ->
          {"Delete schedule", "ryker_delete_schedule", "schedule-control:#{ref}:#{revision}",
           "Stop future runs of “#{title}”. Already-started work and its history remain."}

        "standing_rule" ->
          {"Delete rule", "ryker_delete_behavior", "behavior-control:#{ref}:#{revision}",
           "Stop reacting to “#{title}”. Work it already started and its history remain."}

        "preference" ->
          {"Delete preference", "ryker_delete_behavior", "behavior-control:#{ref}:#{revision}",
           "Stop applying “#{title}”. Replies I already sent stay as they are."}

        "guidance" ->
          {"Delete guidance", "ryker_delete_behavior", "behavior-control:#{ref}:#{revision}",
           "Stop following “#{title}”. Replies I already sent stay as they are."}
      end

    [
      actions(
        "#{ref}:controls",
        resume_control(entity) ++
          [button(action_id, label, value, "danger", "#{label}?", consequence, label)]
      )
    ]
  end

  # A paused rule governs nothing until someone restarts it, and App Home was
  # the only surface that could — one most readers of a channel's list cannot
  # act in. It sits beside the entity's own control, never instead of it.
  defp resume_control(%{"resumable" => true, "ref" => ref, "revision" => revision} = entity) do
    [
      button(
        "ryker_resume_behavior",
        "Resume",
        "behavior-control:#{ref}:#{revision}",
        nil,
        "Resume this rule?",
        "I'll start reacting to “#{entity["title"]}” again from now on. Nothing that happened while it was paused is replayed.",
        "Resume"
      )
    ]
  end

  defp resume_control(_entity), do: []

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(
        %{
          "facts" => facts,
          "instructions" => instructions,
          "kind" => kind,
          "notice" => notice,
          "ref" => ref,
          "removable" => removable,
          "resumable" => resumable,
          "revision" => revision,
          "saved_at" => saved_at,
          "saved_by" => saved_by,
          "status" => status,
          "title" => title
        } = entity
      )
      when map_size(entity) == 12 do
    valid =
      kind in @saved_entity_kinds and status in @saved_entity_statuses and
        is_boolean(removable) and is_boolean(resumable) and
        texts?(title, instructions, notice, saved_by) and
        match?({:ok, _, 0}, DateTime.from_iso8601(saved_at)) and
        ref?(kind, ref, revision) and facts?(facts)

    if valid, do: :ok, else: {:error, :invalid_saved_entity}
  end

  def validate(_entity), do: {:error, :invalid_saved_entity}

  defp texts?(title, instructions, notice, saved_by) do
    text?(title) and String.length(title) <= 300 and
      (is_nil(instructions) or (text?(instructions) and String.length(instructions) <= 2_000)) and
      text?(notice) and text?(saved_by)
  end

  defp ref?("memory", "memory:" <> _rest = ref, nil), do: entity_ref?(ref)

  defp ref?("schedule", "schedule:" <> _rest = ref, revision),
    do: entity_ref?(ref) and positive?(revision)

  defp ref?(kind, "behavior:" <> _rest = ref, revision)
       when kind in ~w(standing_rule preference guidance),
       do: entity_ref?(ref) and positive?(revision)

  defp ref?(_kind, _ref, _revision), do: false

  defp entity_ref?(ref), do: Regex.match?(~r/\A[a-z]+:[A-Za-z0-9_.:-]{1,240}\z/, ref)

  defp positive?(value), do: is_integer(value) and value > 0

  defp facts?(facts) when is_list(facts) and length(facts) <= 10 do
    Enum.all?(facts, fn
      [label, %{"channel_ref" => channel_ref} = value] when map_size(value) == 1 ->
        text?(label) and is_binary(channel_ref)

      [label, value] ->
        text?(label) and text?(value) and String.length(value) <= 1_000

      _other ->
        false
    end)
  end

  defp facts?(_facts), do: false
end
