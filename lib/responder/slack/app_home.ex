defmodule Responder.Slack.AppHome do
  @moduledoc """
  Publishes one bounded, host-rendered Slack App Home view.

  Operational detail is restricted to configured operators. Other active full
  members receive a small availability page, so opening Home cannot disclose
  private incident, task, memory, or schedule state.
  """

  alias Responder.Slack.HomeEvent

  @maximum_attention 8
  @maximum_work 8
  @maximum_incidents 5
  @maximum_behaviors 5
  @maximum_memories 5
  @maximum_memory_reviews 2
  @maximum_schedules 5
  @maximum_text 240

  @spec handle(HomeEvent.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%HomeEvent{} = event, %{} = options) do
    with {:ok, true} <- allowed?(event, options),
         {:ok, access, view} <- view(event, options),
         :ok <- publish(event, view, options) do
      {:ok, %{access: access, outcome: :published}}
    else
      {:ok, false} -> {:ok, %{access: :denied, outcome: :ignored}}
      {:error, _reason} = error -> error
    end
  end

  def handle(_event, _options), do: {:error, {:invalid_app_home, :request}}

  defp allowed?(event, options) do
    with directory when is_atom(directory) <- Map.get(options, :directory),
         client <- Map.get(options, :client),
         true <- function_exported?(directory, :user_allowed, 3) do
      case directory.user_allowed(client, event.actor_ref, event.workspace_ref) do
        {:ok, allowed} when is_boolean(allowed) -> {:ok, allowed}
        {:error, _reason} = error -> error
        _invalid -> {:error, {:invalid_app_home, :directory}}
      end
    else
      _invalid -> {:error, {:invalid_app_home, :directory}}
    end
  end

  defp view(event, options) do
    operators = Map.get(options, :operators)

    if match?(%MapSet{}, operators) and MapSet.member?(operators, event.actor_ref) do
      with projection when is_function(projection, 2) <- Map.get(options, :projection),
           %{} = snapshot <- projection.(event.workspace_ref, event.actor_ref) do
        {:ok, :operator, operator_view(snapshot)}
      else
        _invalid -> {:error, {:invalid_app_home, :projection}}
      end
    else
      if match?(%MapSet{}, operators),
        do: {:ok, :restricted, restricted_view()},
        else: {:error, {:invalid_app_home, :operators}}
    end
  end

  defp publish(event, view, options) do
    with api when is_atom(api) <- Map.get(options, :api),
         client <- Map.get(options, :client),
         true <- function_exported?(api, :publish_home, 3) do
      api.publish_home(client, event.actor_ref, view)
    else
      _invalid -> {:error, {:invalid_app_home, :publisher}}
    end
  end

  defp operator_view(snapshot) do
    needs_attention = bounded_list(snapshot, :needs_attention, @maximum_attention)
    work = bounded_list(snapshot, :work, @maximum_work)
    incidents = bounded_list(snapshot, :incidents, @maximum_incidents)
    behaviors = bounded_list(snapshot, :behaviors, @maximum_behaviors)
    memories = bounded_list(snapshot, :memories, @maximum_memories)
    memory_reviews = bounded_list(snapshot, :memory_reviews, @maximum_memory_reviews)

    memory_review_count =
      bounded_count(Map.get(snapshot, :memory_review_count), length(memory_reviews))

    schedules = bounded_list(snapshot, :schedules, @maximum_schedules)

    blocks =
      [header("Responder"), context("What needs you")]
      |> append_rows(
        needs_attention,
        &attention_block/1,
        "Nothing needs your attention right now."
      )
      |> append_section("In flight", work, &work_block/1)
      |> append_section("Incident rooms", incidents, &incident_block/1)
      |> append_counts(Map.get(snapshot, :counts, %{}))
      |> append_control_section("Memory review", memory_reviews, &memory_review_blocks/1)
      |> append_memory_review_overflow(memory_review_count, length(memory_reviews))
      |> append_control_section("Operational memory", memories, &memory_blocks/1)
      |> append_control_section("Behaviors", behaviors, &behavior_blocks/1)
      |> append_control_section("Schedules", schedules, &schedule_blocks/1)
      |> Kernel.++([
        context("Refreshed when you open Home. Durable state remains authoritative.")
      ])

    %{"blocks" => blocks, "type" => "home"}
  end

  defp restricted_view do
    %{
      "blocks" => [
        header("Responder"),
        section("Responder is available in configured channels."),
        context("Private operational details are limited to configured operators.")
      ],
      "type" => "home"
    }
  end

  defp append_rows(blocks, [], _renderer, empty), do: blocks ++ [section(empty)]

  defp append_rows(blocks, rows, renderer, _empty),
    do: blocks ++ Enum.map(rows, renderer)

  defp append_section(blocks, _title, [], _renderer), do: blocks

  defp append_section(blocks, title, rows, renderer) do
    blocks ++ [divider(), header(title)] ++ Enum.map(rows, renderer)
  end

  defp append_control_section(blocks, _title, [], _renderer), do: blocks

  defp append_control_section(blocks, title, rows, renderer) do
    blocks ++ [divider(), header(title)] ++ Enum.flat_map(rows, renderer)
  end

  defp append_memory_review_overflow(blocks, count, shown) when count > shown do
    blocks ++
      [
        context(
          "#{count - shown} more memory #{if(count - shown == 1, do: "review is", else: "reviews are")} available in the Responder control plane."
        )
      ]
  end

  defp append_memory_review_overflow(blocks, _count, _shown), do: blocks

  defp append_counts(blocks, counts) when is_map(counts) do
    labels = [
      {:active_commitments, "Active commitments"},
      {:blocked_work, "Blocked work"},
      {:open_incidents, "Open incidents"},
      {:incident_history, "Incident history"},
      {:published_work, "Published work"},
      {:active_memory, "Active memories"},
      {:active_behaviors, "Active behaviors"},
      {:active_schedules, "Active schedules"}
    ]

    fields =
      Enum.map(labels, fn {key, label} ->
        count = Map.get(counts, key, 0)
        plain("#{label}: #{if(is_integer(count) and count >= 0, do: count, else: 0)}")
      end)

    blocks ++ [divider(), header("State"), %{"fields" => fields, "type" => "section"}]
  end

  defp append_counts(blocks, _counts), do: append_counts(blocks, %{})

  defp attention_block(row) do
    kind = row |> Map.get(:kind, :attention) |> label()
    section("#{kind}: #{bounded(Map.get(row, :title, Map.get(row, :ref, "Needs attention")))}")
  end

  defp work_block(row) do
    title = bounded(Map.get(row, :title, Map.get(row, :ref, "Work")))
    state = row |> Map.get(:state, :working) |> label()
    next_action = row |> Map.get(:next_action, "continue_work") |> label()
    section("#{title} — #{state}; next: #{next_action}")
  end

  defp incident_block(row) do
    title = bounded(Map.get(row, :title, Map.get(row, :ref, "Incident")))
    status = row |> Map.get(:status, :open) |> label()
    section("#{title} — #{status}")
  end

  defp memory_blocks(row) do
    subject = bounded(Map.get(row, :subject, Map.get(row, :ref, "Memory")))
    kind = row |> Map.get(:kind, :memory) |> label()

    [
      section("#{subject} — #{kind}"),
      actions([
        button(
          "responder_home_forget_memory",
          "Forget",
          Map.get(row, :ref),
          destructive_confirm("Forget this memory?", "The stored value will be redacted.")
        )
      ])
    ]
  end

  defp memory_review_blocks(row) do
    kind = row |> Map.get("kind", "review") |> label()
    review_ref = Map.get(row, "review_ref")
    entries = Map.get(row, "entries", [])
    entry_count = length(entries)
    keep_label = if Map.get(row, "kind") == "duplicate", do: "Keep separate", else: "Keep"

    review_actions = [
      button("responder_home_keep_memory_review", keep_label, review_ref),
      if(Map.get(row, "kind") == "duplicate",
        do:
          button(
            "responder_home_merge_memory_review",
            "Merge (#{entry_count})",
            review_ref,
            destructive_confirm(
              "Merge #{entry_count} entries?",
              "The newest entry will remain; #{max(entry_count - 1, 0)} duplicate values will be redacted.",
              "Merge",
              "Cancel"
            )
          ),
        else: nil
      ),
      button(
        "responder_home_forget_memory_review",
        "Forget all (#{entry_count})",
        review_ref,
        destructive_confirm(
          "Forget all #{entry_count} entries?",
          "Every displayed stored value in this review will be redacted."
        )
      )
    ]

    summary =
      section(
        "#{kind} — #{entry_count} affected #{if(entry_count == 1, do: "entry", else: "entries")}\n#{Map.get(row, "reason", "Review this memory.")}"
      )

    entry_blocks =
      entries
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, index} ->
        section(memory_review_entry(entry, index, entry_count))
      end)

    [summary | entry_blocks] ++ [actions(Enum.reject(review_actions, &is_nil/1))]
  end

  defp memory_review_entry(entry, index, count) do
    subject = bounded_part(Map.get(entry, "subject", "Memory"), 40)
    value = bounded_part(Map.get(entry, "value") || "(redacted)", 72)
    scope = bounded_part(Map.get(entry, "scope", "unknown"), 12)
    scope_ref = bounded_part(Map.get(entry, "scope_ref", "unknown"), 48)
    visibility = bounded_part(Map.get(entry, "visibility", "unknown"), 12)

    "#{index}/#{count} #{subject} — scope: #{scope} (#{scope_ref}); visibility: #{visibility}; value: #{value}"
  end

  defp bounded_count(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp bounded_count(_value, fallback), do: fallback

  defp behavior_blocks(row) do
    subject = bounded(Map.get(row, :subject, Map.get(row, :ref, "Behavior")))
    kind = row |> Map.get(:kind, :behavior) |> label()
    status = Map.get(row, :status, :active)

    status_button =
      case status do
        :disabled -> button("responder_home_enable_behavior", "Enable", Map.get(row, :ref))
        _active -> button("responder_home_disable_behavior", "Disable", Map.get(row, :ref))
      end

    [
      section("#{subject} — #{kind}; #{label(status)}"),
      actions([
        status_button,
        button(
          "responder_home_delete_behavior",
          "Delete",
          Map.get(row, :ref),
          destructive_confirm("Delete this behavior?", "This cannot be re-enabled.")
        )
      ])
    ]
  end

  defp schedule_blocks(row) do
    title = bounded(Map.get(row, :title, Map.get(row, :ref, "Schedule")))
    status = Map.get(row, :status, :active)

    next =
      case Map.get(row, :next_occurrence_at) do
        %DateTime{} = value -> DateTime.to_iso8601(value)
        _unknown -> "next occurrence unavailable"
      end

    status_button =
      case status do
        :paused -> button("responder_home_resume_schedule", "Resume", Map.get(row, :ref))
        _active -> button("responder_home_pause_schedule", "Pause", Map.get(row, :ref))
      end

    [
      section("#{title} — #{label(status)}; #{next}"),
      actions([
        status_button,
        button(
          "responder_home_delete_schedule",
          "Delete",
          Map.get(row, :ref),
          destructive_confirm("Delete this schedule?", "Future occurrences will stop.")
        )
      ])
    ]
  end

  defp bounded_list(snapshot, key, maximum) do
    case Map.get(snapshot, key, []) do
      rows when is_list(rows) -> Enum.take(rows, maximum)
      _invalid -> []
    end
  end

  defp label(value) when is_atom(value), do: value |> Atom.to_string() |> label()

  defp label(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> bounded()
  end

  defp label(_value), do: "unknown"

  defp bounded(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")
    |> String.slice(0, @maximum_text)
  end

  defp bounded(_value), do: "Unknown"

  defp bounded_part(value, maximum) when is_binary(value) do
    value = String.replace(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")

    if String.length(value) > maximum,
      do: String.slice(value, 0, maximum - 1) <> "…",
      else: value
  end

  defp bounded_part(_value, _maximum), do: "unknown"

  defp header(text), do: %{"text" => plain(text), "type" => "header"}
  defp section(text), do: %{"text" => plain(text), "type" => "section"}
  defp context(text), do: %{"elements" => [plain(text)], "type" => "context"}
  defp actions(elements), do: %{"elements" => elements, "type" => "actions"}
  defp divider, do: %{"type" => "divider"}

  defp button(action_id, text, value, confirm \\ nil) do
    button = %{
      "action_id" => action_id,
      "text" => plain(text),
      "type" => "button",
      "value" => bounded(value)
    }

    if confirm, do: Map.put(button, "confirm", confirm), else: button
  end

  defp destructive_confirm(title, text, confirm \\ "Delete", deny \\ "Keep") do
    %{
      "confirm" => plain(confirm),
      "deny" => plain(deny),
      "style" => "danger",
      "text" => plain(text),
      "title" => plain(title)
    }
  end

  defp plain(text), do: %{"emoji" => true, "text" => bounded(text), "type" => "plain_text"}
end
