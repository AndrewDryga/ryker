defmodule Ryker.ControlPlane.RequestFilters do
  @moduledoc "Editable request criteria. Drafts change this view, never execution state."
  use Phoenix.Component
  alias Ryker.ControlPlane.{Components, SlackNames, UsagePage, UsageProjection}

  @fields [
    {"state", "Request state",
     ~w(working waiting_for_input waiting_for_event complete cancelled)},
    {"repository", "Repository", :text},
    {"target", "Execution target", :text},
    {"conversation", "Conversation", :conversation},
    {"thread", "Thread", :text},
    {"transport", "Conversation platform", ~w(slack github control_plane)},
    {"usage_profile", "Profile", :text},
    {"usage_model", "Model", :text},
    {"usage_effort", "Reasoning effort", ~w(none minimal low medium high xhigh max)},
    {"usage_provider", "Provider", :text},
    {"usage_actor", "Person", :person},
    {"usage_channel", "Channel", :channel},
    {"usage_repository", "Usage repository", :text},
    {"usage_work_kind", "Work type",
     ~w(admission learning conversational standard deep continuation resumed task event_wait schedule publication approval unclassified)},
    {"usage_source", "Input source", ~w(slack github webhook control_plane)},
    {"usage_actor_kind", "Sender type", ~w(user app bot system)},
    {"usage_workspace", "Source workspace", :text},
    {"usage_transport", "Delivery platform", ~w(slack github control_plane)},
    {"usage_measurement", "Token report", ~w(measured missing)},
    {"usage_target", "Exact usage target", :text},
    {"usage_window", "Usage period", ~w(24h 7d 30d all)}
  ]
  @keys Enum.map(@fields, &elem(&1, 0))
  @missing_values %{"usage_provider" => "unrecorded", "usage_work_kind" => "unclassified"}
  def keys, do: @keys

  def draft(params) do
    safe = UsageProjection.link_params(params)

    safe =
      if UsageProjection.filtered?(safe),
        do: Map.put(safe, "usage_window", UsageProjection.window(safe["usage_window"])),
        else: safe

    safe
    |> Map.take(@keys)
    |> Map.new(fn {key, value} ->
      missing? = nullable?(key) and value == Map.get(@missing_values, key, "")

      {key,
       %{
         "match" => if(missing?, do: "missing", else: "equals"),
         "value" => if(missing?, do: "", else: value)
       }}
    end)
  end

  def edit(draft, params) do
    submitted = params["criteria"]
    submitted = if is_map(submitted), do: submitted, else: %{}

    draft =
      Enum.reduce(submitted, draft, fn
        {key, %{"match" => match, "value" => value}}, acc
        when key in @keys and match in ~w(equals missing any) and is_binary(value) and
               byte_size(value) <= 512 ->
          Map.put(acc, key, %{"match" => match, "value" => value})

        {key, %{"match" => match}}, acc when key in @keys and match in ~w(missing any) ->
          Map.put(acc, key, %{"match" => match, "value" => ""})

        {key, %{"match" => "equals"}}, acc when key in @keys ->
          Map.put(acc, key, %{"match" => "equals", "value" => get_in(acc, [key, "value"]) || ""})

        _, acc ->
          acc
      end)

    case params["add_filter"] do
      key when key in @keys -> Map.put_new(draft, key, %{"match" => "equals", "value" => ""})
      _ -> draft
    end
  end

  def apply(params, submitted) do
    changes =
      edit(%{}, submitted)
      |> Enum.flat_map(&criterion_param/1)
      |> Map.new()

    changes =
      if changes["usage_actor"] in [nil, ""],
        do: changes,
        else: Map.put_new(changes, "usage_actor_kind", "user")

    params |> UsageProjection.link_params() |> Map.take(~w(q mode filter)) |> Map.merge(changes)
  end

  defp criterion_param({key, %{"match" => "equals", "value" => value}}) when value != "",
    do: [{key, value}]

  defp criterion_param({key, %{"match" => "missing"}}),
    do: if(nullable?(key), do: [{key, Map.get(@missing_values, key, "")}], else: [])

  defp criterion_param(_), do: []

  defp usage_path(params) do
    mode = if params["mode"] in ~w(all shadow), do: params["mode"], else: "live"

    "/usage?" <>
      URI.encode_query(%{window: UsageProjection.window(params["usage_window"]), mode: mode})
  end

  def clear_usage(path, params),
    do:
      path <>
        "?" <>
        URI.encode_query(
          params
          |> UsageProjection.link_params()
          |> Map.take(~w(q mode filter state target repository conversation thread transport))
        )

  def render(assigns) do
    assigns =
      assign(assigns, :fields, Enum.filter(@fields, &Map.has_key?(assigns.draft, elem(&1, 0))))

    assigns =
      assign(assigns, :available, Enum.reject(@fields, &Map.has_key?(assigns.draft, elem(&1, 0))))

    ~H"""
    <form
      id="request-criteria"
      class="request-criteria"
      phx-change="edit-request-filters"
      phx-submit="apply-request-filters"
    >
      <div class="criteria-heading">
        <h2>Filters</h2>
        <label class="sr-only" for="request-filter-add">Add a filter</label>
        <select id="request-filter-add" name="add_filter">
          <option value="" selected>Add filter…</option>
          <option :for={{key, label, _} <- @available} value={key}>{label}</option>
        </select>
        <button :if={@fields != []} type="submit" class="ui-button primary">Apply filters</button>
        <.link :if={@fields != []} class="ui-button secondary" patch={@path}>Clear all filters</.link>
        <div :if={UsageProjection.filtered?(@params)} class="usage-drilldown">
          <a class="ui-button secondary" href={usage_path(@params)}>Back to Usage</a>
          <.link class="ui-button secondary" patch={clear_usage(@path, @params)}>Clear usage filters</.link>
        </div>
      </div>
      <div :if={@fields != []} class="criteria-grid">
        <div :for={{key, label, type} <- @fields} class="criterion">
          <label for={"criterion-#{key}"}>{label}</label>
          <div class="criterion-controls">
            <select
              name={"criteria[#{key}][match]"}
              aria-label={"#{label} match"}
              class={if @draft[key]["match"] == "missing", do: "match-missing"}
            >
              <option value="equals" selected={@draft[key]["match"] == "equals"}>Is</option>
              <option
                :if={nullable?(key)}
                value="missing"
                selected={@draft[key]["match"] == "missing"}
              >
                Not recorded
              </option>
              <option value="any" selected={@draft[key]["match"] == "any"}>Any</option>
            </select>
            <input
              :if={type == :text}
              id={"criterion-#{key}"}
              name={"criteria[#{key}][value]"}
              value={@draft[key]["value"]}
              disabled={@draft[key]["match"] != "equals"}
              type="text"
              maxlength="512"
              autocomplete="off"
              phx-debounce="300"
            />
            <select
              :if={type != :text}
              id={"criterion-#{key}"}
              name={"criteria[#{key}][value]"}
              disabled={@draft[key]["match"] != "equals"}
            >
              <option value="">Select…</option>
              <option
                :for={{value, name} <- choices(type, @values, @draft[key]["value"], @params)}
                value={value}
                selected={value == @draft[key]["value"]}
                title={value}
              >
                {name}
              </option>
            </select>
          </div>
        </div>
      </div>
    </form>
    """
  end

  defp nullable?(key),
    do: String.starts_with?(key, "usage_") and key not in ~w(usage_window usage_measurement)

  defp choices(type, rows, selected, params) do
    options =
      case type do
        :conversation ->
          rows
          |> Enum.filter(&Map.has_key?(&1, :conversation_label))
          |> Enum.map(&{&1.conversation_ref, &1.conversation_label})

        :person ->
          rows
          |> Enum.filter(&(&1.actor_kind == "user" and &1.source != "control_plane"))
          |> Enum.map(fn row ->
            {row.actor,
             if(row.source == "slack",
               do: SlackNames.name(row.workspace, row.actor),
               else: row.actor
             )}
          end)

        :channel ->
          rows
          |> Enum.filter(&(&1.transport == "slack"))
          |> Enum.map(&{&1.conversation_ref, SlackNames.destination(&1.conversation_ref)})

        values ->
          Enum.map(values, &{&1, choice_label(&1)})
      end

    options =
      Enum.reject(options, fn {value, _} -> value in [nil, ""] end) |> Enum.uniq_by(&elem(&1, 0))

    if selected in [nil, ""] or Enum.any?(options, &(elem(&1, 0) == selected)),
      do: options,
      else: options ++ [{selected, selected_label(type, selected, params)}]
  end

  defp selected_label(:person, value, %{"usage_source" => "slack", "usage_workspace" => workspace}),
       do: SlackNames.name(workspace, value)

  defp selected_label(:channel, value, _), do: SlackNames.destination(value)
  defp selected_label(:conversation, value, _), do: SlackNames.destination(value)
  defp selected_label(_, value, _), do: value
  defp choice_label("control_plane"), do: "Direct conversation"
  defp choice_label("github"), do: "GitHub"
  defp choice_label("user"), do: "Person"
  defp choice_label("measured"), do: "Recorded"
  defp choice_label("missing"), do: "Missing"
  defp choice_label("24h"), do: "Last 24 hours"
  defp choice_label("7d"), do: "Last 7 days"
  defp choice_label("30d"), do: "Last 30 days"
  defp choice_label("all"), do: "All time"
  # The filter must offer the same words the breakdown shows, or "Investigation"
  # in the table and "Standard" in the dropdown look like two different things.
  defp choice_label(value) do
    if value in UsagePage.work_kinds(),
      do: UsagePage.kind_name(value),
      else: Components.label(value)
  end
end
