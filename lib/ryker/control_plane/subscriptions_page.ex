defmodule Ryker.ControlPlane.SubscriptionsPage do
  @moduledoc """
  Automations › Follow-ups: work Ryker paused and will pick up again at a set
  time or when something happens.

  Each row follows the Kit: what the follow-up waits for and its state, the
  request it continues, then when and where in words. Ryker creates and ends
  these itself, so the page is read-only; the identifiers support needs stay
  in one closed Details disclosure per row.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, ShortTime}
  alias Ryker.ControlPlane.SubscriptionPresentation, as: Presentation

  @list_limit 100

  @doc "The one sentence under the page title."
  @spec description() :: String.t()
  def description,
    do: "Work Ryker paused and will pick up again at a set time or when something happens."

  @doc "The list's query: the search, and whether it shows current or past follow-ups."
  @spec params(map()) :: %{String.t() => String.t()}
  def params(params) do
    query = if is_binary(params["q"]), do: String.slice(params["q"], 0, 200), else: ""
    %{"q" => query, "view" => if(params["view"] == "past", do: "past", else: "current")}
  end

  @doc "The Follow-ups list: the toolbar, the rows, and how follow-ups come to exist."
  @spec list([map()], map(), DateTime.t()) :: iodata()
  def list(items, params, now \\ DateTime.utc_now()) do
    %{
      __changed__: nil,
      items: items,
      query: params["q"] || "",
      view: params["view"] || "current",
      now: now
    }
    |> render()
    |> Safe.to_iodata()
  end

  @doc "The list body for `items`, the search `query`, the `view` and the clock `now`."
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:query, fn -> "" end)
      |> assign_new(:view, fn -> "current" end)
      |> assign_new(:now, &DateTime.utc_now/0)
      |> assign(:full, length(assigns.items) >= @list_limit)
      |> assign(:items, Enum.take(assigns.items, @list_limit))

    ~H"""
    <div class="follow-ups-view">
      <Kit.toolbar>
        <Components.filter_toolbar
          id="operator-search"
          path="/follow-ups"
          label="Search follow-ups"
          placeholder="Search follow-ups"
          query={@query}
          filtered={@query != ""}
          hidden={if @view == "past", do: [{"view", "past"}], else: []}
          clear={view_path("", @view)}
        />
        <Kit.segmented label="Which follow-ups" options={segments(@query, @view)} />
      </Kit.toolbar>
      <Kit.entity_list :if={@items != []} label="Follow-ups">
        <Kit.entity_row
          :for={item <- @items}
          id={"follow-up-" <> item.ref}
          icon={:bell}
          name={item.title}
          state={Presentation.status(item)}
          text={continues(item)}
          meta={facts(item, @now)}
        >
          <:details>
            <Components.disclosure
              id={"follow-up-details-" <> item.ref}
              label="Details"
              summary_aria_label={"Details for " <> item.title}
              class="follow-up-details"
            >
              <Components.fact_list facts={details(item)} />
            </Components.disclosure>
          </:details>
        </Kit.entity_row>
      </Kit.entity_list>
      <p :if={@full} class="follow-up-note">Showing the first 100 follow-ups.</p>
      <.list_empty :if={@items == []} query={@query} view={@view} />
      <Kit.ask_hint
        lead="Ryker adds follow-ups on its own when work has to wait. You can also ask:"
        example="Check again tomorrow morning."
      />
    </div>
    """
  end

  attr(:query, :string, required: true)
  attr(:view, :string, required: true)

  defp list_empty(%{query: query} = assigns) when query != "" do
    ~H"""
    <Kit.empty
      title={"No follow-ups match “#{@query}”"}
      text={"Try other words, or look under #{if @view == "past", do: "Current", else: "Past"}."}
    />
    """
  end

  defp list_empty(%{view: "past"} = assigns) do
    ~H"""
    <Kit.empty
      title="No past follow-ups"
      text="Follow-ups move here once the work continues, the deadline passes or they are cancelled."
    />
    """
  end

  defp list_empty(assigns) do
    ~H"""
    <Kit.empty
      title="Nothing is waiting"
      text="When Ryker has to pause a request until a set time or an update, it shows here."
    />
    """
  end

  # The request this follow-up belongs to, linked to its timeline.
  defp continues(%{episode_title: title, episode_href: href} = item) when is_binary(title) do
    assigns = %{lead: lead(item), title: title, href: href}

    ~H"""
    {@lead}: <a :if={@href} href={@href}>{@title}</a><span :if={!@href}>{@title}</span>
    """
  end

  defp continues(_item), do: "Continues a request that is no longer available."

  defp lead(%{status: :active}), do: "Continues"
  defp lead(%{status: :cancelled}), do: "Part of"
  defp lead(_item), do: "Continued"

  defp facts(item, now) do
    Enum.map(Presentation.timing(item, now), &moment/1) ++
      [place(item[:place]), repository(item[:repository]), target(item)]
  end

  defp place(nil), do: nil
  defp place(:direct), do: "in a direct conversation"
  defp place(name), do: labelled("in ", name)

  defp repository(nil), do: nil
  defp repository(name), do: labelled("repository ", name)

  defp target(%{target_url: url} = item) when is_binary(url) do
    assigns = %{url: url, title: item.title}

    ~H"""
    <a href={@url} rel="noreferrer" aria-label={"Open target for " <> @title}>Open target ↗</a>
    """
  end

  defp target(_item), do: nil

  defp details(item) do
    [
      %{label: "Follow-up ID", value: item.ref, identifier: true},
      item[:condition] && %{label: "Matches", value: item.condition},
      %{label: "Source revision", value: to_string(item.revision)}
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(if item.status == :timed_out, do: outcome_references(item), else: [])
  end

  # Once a follow-up gave up, the digests of what it last saw explain why.
  defp outcome_references(item) do
    for {label, value} <- [
          {"Matcher reference", item.matcher_digest},
          {"Cursor reference", item.cursor_digest},
          {"Observation reference", item.last_observation_digest}
        ],
        value,
        do: %{label: label, value: value, identifier: true}
  end

  defp moment({text, nil}), do: text

  defp moment({text, %DateTime{} = at}) do
    assigns = %{text: text, at: at}

    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={ShortTime.full(@at)}>{@text}</time>
    """
  end

  defp labelled(lead, value) do
    assigns = %{lead: lead, value: value}
    ~H"{@lead}<strong>{@value}</strong>"
  end

  defp segments(query, view) do
    [
      {"Current", view_path(query, "current"), view == "current"},
      {"Past", view_path(query, "past"), view == "past"}
    ]
  end

  defp view_path(query, view) do
    [{"q", query}, {"view", if(view == "past", do: "past")}]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> case do
      [] -> "/follow-ups"
      params -> "/follow-ups?" <> URI.encode_query(params)
    end
  end
end
