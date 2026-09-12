defmodule Responder.Slack.AppHome do
  @moduledoc """
  Publishes one bounded, host-rendered Slack App Home view.

  Operational detail is restricted to configured operators. Other active full
  members receive a small availability page, so opening Home cannot disclose
  private incident, task, memory, or schedule state.

  The dashboard sections are a capped digest. `publish_collection/4` opens the
  complete authorized list of one collection in the same Home tab, one bounded
  page at a time, which is what a channel card means when it says an operator
  can open Home for the complete list.
  """

  alias Responder.Slack.{Collections, HomeEvent}

  @maximum_attention 8
  @maximum_work 8
  @maximum_incidents 5
  @maximum_behaviors 5
  @maximum_memories 5
  @maximum_memory_reviews 2
  @maximum_schedules 5
  @maximum_collection_rows 10
  @maximum_text 240
  @action_instance_separator "__i"

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

  @doc """
  Publishes one bounded page of a collection's complete authorized list.

  The page is read again on every click, so it carries the reader's current
  channel access rather than the access they had when the button was rendered.
  """
  @spec publish_collection(HomeEvent.t(), Collections.kind(), non_neg_integer(), map()) ::
          {:ok, map()} | {:error, term()}
  def publish_collection(%HomeEvent{} = event, kind, offset, %{} = options) do
    with {:ok, true} <- allowed?(event, options),
         {:ok, access, view} <- collection_page(event, kind, offset, options),
         :ok <- publish(event, view, options) do
      {:ok, %{access: access, outcome: :published}}
    else
      {:ok, false} -> {:ok, %{access: :denied, outcome: :ignored}}
      {:error, _reason} = error -> error
    end
  end

  def publish_collection(_event, _kind, _offset, _options),
    do: {:error, {:invalid_app_home, :request}}

  @doc false
  @spec render(:collection | :operator | :restricted, map()) :: map()
  def render(:collection, %{} = collection), do: collection_view(collection)
  def render(:operator, %{} = snapshot), do: operator_view(snapshot)
  def render(:restricted, %{}), do: restricted_view()

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
    authorized_view(event, options, fn shared_conversations ->
      with projection when is_function(projection, 3) <- Map.get(options, :projection),
           %{} = snapshot <-
             projection.(event.workspace_ref, event.actor_ref, shared_conversations) do
        {:ok, operator_view(snapshot)}
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, {:invalid_app_home, :projection}}
      end
    end)
  end

  defp collection_page(event, kind, offset, options) do
    authorized_view(event, options, fn shared_conversations ->
      with projection when is_function(projection, 4) <- Map.get(options, :collection),
           %{} = collection <-
             projection.(kind, event.workspace_ref, shared_conversations, offset) do
        {:ok, collection_view(collection)}
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, {:invalid_app_home, :collection}}
      end
    end)
  end

  # One place decides who sees operational detail, so the dashboard and the
  # complete lists cannot drift apart on who is an operator.
  defp authorized_view(event, options, build) do
    operators = Map.get(options, :operators)

    cond do
      not match?(%MapSet{}, operators) ->
        {:error, {:invalid_app_home, :operators}}

      not MapSet.member?(operators, event.actor_ref) ->
        {:ok, :restricted, restricted_view()}

      true ->
        with {:ok, shared_conversations} <- shared_conversations(event, options),
             {:ok, view} <- build.(shared_conversations) do
          {:ok, :operator, view}
        end
    end
  end

  defp shared_conversations(event, options) do
    case Map.get(options, :shared_conversations) do
      callback when is_function(callback, 3) ->
        case callback.(Map.get(options, :client), event.actor_ref, event.workspace_ref) do
          {:ok, %MapSet{} = conversations} -> {:ok, conversations}
          {:error, _reason} = error -> error
          _invalid -> {:error, {:invalid_app_home, :shared_conversations}}
        end

      _missing ->
        {:error, {:invalid_app_home, :shared_conversations}}
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
        &attention_blocks/1,
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
        collection_controls(),
        context("Refreshed when you open Home. Durable state remains authoritative.")
      ])
      |> unique_action_ids()

    %{"blocks" => blocks, "type" => "home"}
  end

  # The sections above are a capped digest of what is active. These open the
  # complete authorized list a channel card points an operator at.
  defp collection_controls do
    actions(
      Enum.map(
        [
          {:schedules, "All schedules"},
          {:standing_rules, "All standing rules"},
          {:knowledge, "All saved knowledge"}
        ],
        fn {kind, text} ->
          button("responder_home_show_collection", text, collection_value(kind, 0))
        end
      )
    )
  end

  defp collection_value(kind, offset), do: "home-collection:#{kind}:#{offset}"

  defp collection_view(collection) do
    kind = Map.get(collection, :kind)
    rows = collection |> Map.get(:rows, []) |> List.wrap()

    blocks =
      [header(collection_title(kind)), collection_summary_block(collection)] ++
        Enum.map(rows, &collection_row/1) ++
        [actions(collection_page_controls(collection))]

    %{"blocks" => unique_action_ids(blocks), "type" => "home"}
  end

  # A count belongs in the quiet line above a list; "this could not be loaded"
  # is the answer itself and is read as body text.
  defp collection_summary_block(%{outcome: outcome} = collection)
       when outcome in [:empty, :unavailable],
       do: section(collection_summary(collection))

  defp collection_summary_block(collection), do: context(collection_summary(collection))

  defp collection_row(row) do
    title = bounded(Map.get(row, :title) || Map.get(row, :ref, "Saved item"))
    detail = bounded_part(Map.get(row, :detail) || "Saved", 60)
    section("#{title} — #{detail}", open_button(row))
  end

  defp collection_page_controls(collection) do
    kind = Map.get(collection, :kind)
    offset = Map.get(collection, :offset, 0)
    page_size = collection_page_size(collection)
    total = Map.get(collection, :total, 0)

    [
      if(offset > 0,
        do:
          button(
            "responder_home_show_collection",
            "Previous",
            collection_value(kind, max(offset - page_size, 0))
          )
      ),
      if(offset + page_size < total,
        do:
          button(
            "responder_home_show_collection",
            "Next",
            collection_value(kind, offset + page_size)
          )
      ),
      button("responder_home_show_dashboard", "Back to Home", "home-collection:dashboard")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp collection_summary(%{outcome: :unavailable} = collection),
    do:
      "I couldn't load your #{collection_label(Map.get(collection, :kind))} right now. " <>
        "Try again in a moment."

  defp collection_summary(%{outcome: :empty} = collection),
    do: collection_empty(Map.get(collection, :kind))

  defp collection_summary(collection) do
    total = Map.get(collection, :total, 0)
    page_size = collection_page_size(collection)
    pages = max(ceil(total / page_size), 1)
    page = div(Map.get(collection, :offset, 0), page_size) + 1
    counted = "#{total} #{collection_label(Map.get(collection, :kind))} in the channels we share"

    if pages > 1, do: "#{counted} · page #{page} of #{pages}", else: "#{counted}."
  end

  defp collection_page_size(collection) do
    case Map.get(collection, :page_size) do
      size when is_integer(size) and size > 0 -> size
      _unknown -> @maximum_collection_rows
    end
  end

  defp collection_title(:schedules), do: "All active schedules"
  defp collection_title(:standing_rules), do: "All active standing rules"
  defp collection_title(:knowledge), do: "All saved knowledge"
  defp collection_title(_kind), do: "Saved items"

  defp collection_label(:schedules), do: "schedules"
  defp collection_label(:standing_rules), do: "standing rules"
  defp collection_label(:knowledge), do: "saved knowledge items"
  defp collection_label(_kind), do: "saved items"

  defp collection_empty(:schedules),
    do: "No active schedules are set up in the channels we share."

  defp collection_empty(:standing_rules),
    do: "No standing rules are set up in the channels we share."

  defp collection_empty(:knowledge),
    do: "I haven't saved any preferences, guidance or memories in the channels we share."

  defp collection_empty(_kind), do: "Nothing is saved in the channels we share."

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
    do: blocks ++ Enum.flat_map(rows, &(renderer.(&1) |> List.wrap()))

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
      {:retained_workspaces, "Retained workspaces"},
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

  defp attention_blocks(row) do
    kind = row |> Map.get(:kind, :attention) |> label()
    summary = "#{kind}: #{bounded(Map.get(row, :title, Map.get(row, :ref, "Needs attention")))}"

    [section(summary, open_button(row))]
    |> append_attention_controls(row)
  end

  defp work_block(row) do
    title = bounded(Map.get(row, :title, Map.get(row, :ref, "Work")))
    state = row |> Map.get(:state, :working) |> label()
    next_action = row |> Map.get(:next_action, "continue_work") |> label()
    section("#{title} — #{state}; next: #{next_action}", open_button(row))
  end

  defp incident_block(row) do
    title = bounded(Map.get(row, :title, Map.get(row, :ref, "Incident")))
    status = row |> Map.get(:status, :open) |> label()
    section("#{title} — #{status}", open_button(row))
  end

  defp memory_blocks(row) do
    subject = bounded(Map.get(row, :subject, Map.get(row, :ref, "Memory")))
    kind = row |> Map.get(:kind, :memory) |> label()

    [
      section("#{subject} — #{kind}", open_button(row)),
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
      if(editable_memory_review?(row),
        do: button("responder_home_edit_memory_review", "Edit…", review_ref),
        else: nil
      ),
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
        section(memory_review_entry(entry, index, entry_count), open_button(entry))
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

  defp editable_memory_review?(%{
         "kind" => "stale",
         "entries" => [%{"subject" => subject, "value" => value}]
       }) do
    bounded_input?(subject, 120) and bounded_input?(value, 4_000)
  end

  defp editable_memory_review?(_review), do: false

  defp bounded_input?(value, maximum) when is_binary(value) do
    length = value |> String.trim() |> String.length()
    length in 1..maximum
  end

  defp bounded_input?(_value, _maximum), do: false

  defp bounded_count(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp bounded_count(_value, fallback), do: fallback

  defp behavior_blocks(row) do
    subject = bounded(Map.get(row, :subject, Map.get(row, :ref, "Behavior")))
    kind = row |> Map.get(:kind, :behavior) |> label()
    status = Map.get(row, :status, :active)

    status_button =
      case status do
        :disabled ->
          button("responder_home_enable_behavior", "Enable", versioned_control(:behavior, row))

        _active ->
          button("responder_home_disable_behavior", "Disable", versioned_control(:behavior, row))
      end

    [
      section("#{subject} — #{kind}; #{label(status)}", open_button(row)),
      actions([
        status_button,
        button(
          "responder_home_delete_behavior",
          "Delete",
          versioned_control(:behavior, row),
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
        :paused ->
          button("responder_home_resume_schedule", "Resume", versioned_control(:schedule, row))

        :active ->
          button("responder_home_pause_schedule", "Pause", versioned_control(:schedule, row))

        _terminal ->
          nil
      end

    [
      section("#{title} — #{label(status)}; #{next}"),
      actions(
        [
          button("responder_home_run_schedule", "Run now", Map.get(row, :ref)),
          status_button,
          open_button(row, "Replace in chat"),
          if(status in [:active, :paused],
            do:
              button(
                "responder_home_delete_schedule",
                "Delete",
                versioned_control(:schedule, row),
                destructive_confirm("Delete this schedule?", "Future occurrences will stop.")
              ),
            else: nil
          )
        ]
        |> Enum.reject(&is_nil/1)
      )
    ]
  end

  defp append_attention_controls(blocks, %{controls: controls} = row) when is_list(controls) do
    buttons =
      controls
      |> Enum.map(&attention_control(&1, row))
      |> Enum.reject(&is_nil/1)

    if buttons == [], do: blocks, else: blocks ++ [actions(buttons)]
  end

  defp append_attention_controls(blocks, _row), do: blocks

  defp attention_control("retry", row),
    do: publication_button(row, "responder_home_retry_publication", "Retry publication")

  defp attention_control("update", row),
    do: publication_button(row, "responder_home_update_publication", "Review latest state")

  defp attention_control("discard", row) do
    publication_button(
      row,
      "responder_home_discard_publication",
      "Discard candidate",
      destructive_confirm(
        "Discard this publication candidate?",
        "The reviewed publication custody will become terminal."
      )
    )
  end

  defp attention_control("discard_workspace", row) do
    with ref when is_binary(ref) <- Map.get(row, :ref),
         fingerprint when is_binary(fingerprint) <- Map.get(row, :discard_plan_fingerprint) do
      button(
        "responder_home_discard_workspace",
        "Discard retained work",
        "responder-work-control:#{ref}:#{fingerprint}",
        destructive_confirm(
          "Discard this retained workspace?",
          "Responder will obtain a fresh exact plan. Dirty work remains protected."
        )
      )
    else
      _invalid -> nil
    end
  end

  defp attention_control(_control, _row), do: nil

  defp publication_button(row, action_id, text, confirm \\ nil) do
    with ref when is_binary(ref) <- Map.get(row, :ref),
         generation when is_integer(generation) and generation > 0 <-
           Map.get(row, :recovery_generation),
         "publication:" <> id <- ref do
      button(action_id, text, "publication-recovery:#{id}:#{generation}", confirm)
    else
      _invalid -> nil
    end
  end

  defp open_button(row, text \\ "Open") do
    url = Map.get(row, :url, Map.get(row, "url"))
    ref = Map.get(row, :ref, Map.get(row, "memory_ref"))

    case {url, ref} do
      {"https://slack.com/app_redirect?" <> _rest = url, ref} when is_binary(ref) ->
        button("responder_home_open", text, ref, nil, url)

      _missing ->
        nil
    end
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
  defp section(text), do: section(text, nil)

  defp section(text, accessory) do
    block = %{"text" => plain(text), "type" => "section"}
    if is_map(accessory), do: Map.put(block, "accessory", accessory), else: block
  end

  defp context(text), do: %{"elements" => [plain(text)], "type" => "context"}
  defp actions(elements), do: %{"elements" => elements, "type" => "actions"}
  defp divider, do: %{"type" => "divider"}

  defp button(action_id, text, value, confirm \\ nil, url \\ nil) do
    button = %{
      "action_id" => action_id,
      "text" => plain(text),
      "type" => "button",
      "value" => bounded_part(value, 256)
    }

    button = if confirm, do: Map.put(button, "confirm", confirm), else: button
    if url, do: Map.put(button, "url", url), else: button
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

  defp unique_action_ids(blocks) do
    {blocks, _occurrences} = Enum.map_reduce(blocks, %{}, &unique_block_action_ids/2)
    blocks
  end

  defp unique_block_action_ids(block, occurrences) do
    {block, occurrences} = unique_accessory_action_id(block, occurrences)
    unique_element_action_ids(block, occurrences)
  end

  defp unique_accessory_action_id(%{"accessory" => accessory} = block, occurrences) do
    {accessory, occurrences} = unique_action_id(accessory, occurrences)
    {Map.put(block, "accessory", accessory), occurrences}
  end

  defp unique_accessory_action_id(block, occurrences), do: {block, occurrences}

  defp unique_element_action_ids(%{"elements" => elements} = block, occurrences)
       when is_list(elements) do
    {elements, occurrences} = Enum.map_reduce(elements, occurrences, &unique_action_id/2)
    {Map.put(block, "elements", elements), occurrences}
  end

  defp unique_element_action_ids(block, occurrences), do: {block, occurrences}

  defp unique_action_id(%{"action_id" => action_id} = element, occurrences)
       when is_binary(action_id) do
    instance = Map.get(occurrences, action_id, 0) + 1
    occurrences = Map.put(occurrences, action_id, instance)

    if instance == 1,
      do: {element, occurrences},
      else:
        {Map.put(element, "action_id", "#{action_id}#{@action_instance_separator}#{instance}"),
         occurrences}
  end

  defp unique_action_id(element, occurrences), do: {element, occurrences}

  defp versioned_control(kind, row) do
    case {Map.get(row, :ref), Map.get(row, :revision)} do
      {ref, revision} when is_binary(ref) and is_integer(revision) and revision > 0 ->
        "#{kind}-control:#{ref}:#{revision}"

      _invalid ->
        nil
    end
  end

  defp plain(text), do: %{"emoji" => true, "text" => bounded(text), "type" => "plain_text"}
end
