defmodule Ryker.ControlPlane.FeedbackPage do
  @moduledoc """
  Feedback (`/memory/feedback`): what people told Ryker about its answers,
  by category, frustrated first, and over time (`Ryker.Feedback`,
  `Ryker.ControlPlane.FeedbackProjection`).

  Andrew, 2026-09-27: "let users see feedback by category in UI, do
  something about it (at very least see where users were frustrated to see
  what happened and fix the issue)". The page leads with how much of each
  kind there is, then a table of the latest days, then the newest few of
  each kind, frustrated first, each opening the request's Timeline where it
  happened. One kind is a page of its own, every signal newest first under
  day headings. It is a page of the Memory group: what people said about
  the answers is what the learning and self-improvement loops read, and it
  is history, not live work.

  Everything here is a Kit part. The words each signal reads in (`state/1`,
  `text/1`, `icon/1`) are shared with the request's Feedback chapter on its
  Timeline. The page redraws when feedback is recorded (`subscriptions/0`).
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [filter_toolbar: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Emoji, FeedbackProjection, ImprovementPage, Kit, ShortTime}
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate

  @path "/memory/feedback"

  @doc """
  The topics an open Feedback page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`).
  """
  def subscriptions,
    do: [
      {Ryker.Feedback, :subscribe_feedback, []},
      {Ryker.Improvement, :subscribe_improvement, []}
    ]

  @doc "The one sentence under the page title."
  def description,
    do:
      "What people told Ryker about its answers, and how they felt, with the request each one is about."

  @doc """
  The heading of one category's page, or nil on the page of every category:
  its title, what it holds, and the way back to all feedback.
  """
  @spec heading(map()) :: map() | nil
  def heading(%{category: nil}), do: nil

  def heading(%{category: category}) do
    %{
      title: label(category),
      description: lede(category),
      back: {"All feedback", @path}
    }
  end

  @doc "The Feedback body for a `FeedbackProjection.page/1` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  def render(assigns) do
    now = DateTime.utc_now()

    assigns =
      assigns
      |> assign(:now, now)
      |> assign(:today, DateTime.to_date(now))
      |> assign(:columns, columns(assigns.view.days))
      |> assign(:path, @path)

    ~H"""
    <div class="memory-view memory-feedback">
      <Kit.counts label="Feedback" items={counts(@view)} />
      <Kit.toolbar :if={@view.total > 0 or @view.q != ""}>
        <.filter_toolbar
          id="feedback-search"
          path={@path}
          hidden={hidden(@view)}
          label="Search feedback"
          placeholder="Search feedback"
          query={@view.q}
          filtered={@view.q != ""}
        />
      </Kit.toolbar>
      <%= if @view.category do %>
        <.category_list view={@view} today={@today} />
      <% else %>
        <.overview view={@view} columns={@columns} today={@today} now={@now} />
      <% end %>
    </div>
    """
  end

  attr(:view, :map, required: true)
  attr(:columns, :list, required: true)
  attr(:today, :any, required: true)
  attr(:now, :any, required: true)

  defp overview(assigns) do
    ~H"""
    <Kit.empty
      :if={@view.total == 0 and @view.q != ""}
      icon={:search}
      title={"No feedback matches “#{@view.q}”"}
      text="Try other words, or clear the search to see all feedback."
    />
    <Kit.empty
      :if={@view.total == 0 and @view.q == ""}
      icon={:chat}
      title="No feedback yet"
      text="When people react to Ryker's answers, ask the same thing again, change their message after an answer or say how an answer landed, it shows here."
    />
    <section
      :if={@view.q == "" and fix_total(Map.get(@view, :improvement)) > 0}
      aria-labelledby="feedback-fix"
    >
      <Kit.section_head
        id="feedback-fix"
        title="What to fix"
        lede="Requests people were unhappy with, each with Ryker's own diagnosis of what went wrong."
      >
        <:actions>
          <.link navigate={ImprovementPage.path()}>Review</.link>
        </:actions>
      </Kit.section_head>
      <Kit.counts label="What to fix" items={fix_counts(@view.improvement)} />
      <Kit.counts
        :if={@view.improvement.categories != %{}}
        label="What went wrong, of those to decide"
        secondary
        items={fix_categories(@view.improvement)}
      />
    </section>
    <section :if={@view.days != []} aria-labelledby="feedback-by-day">
      <Kit.section_head
        id="feedback-by-day"
        title="By day"
        lede="How much of each kind came in on each of the latest days, newest first."
      />
      <Kit.table rows={@view.days} label="Feedback by day">
        <:col :let={day} label="Day">{Kit.day_label(day.day, @today)}</:col>
        <:col :let={day} :for={category <- @columns} label={label(category)} numeric>
          {Map.get(day.counts, category, 0)}
        </:col>
      </Kit.table>
    </section>
    <section
      :for={group <- @view.groups}
      id={"feedback-" <> Atom.to_string(group.category)}
      aria-labelledby={"feedback-#{group.category}-title"}
    >
      <Kit.section_head
        id={"feedback-#{group.category}-title"}
        title={label(group.category)}
        lede={lede(group.category)}
      >
        <:actions :if={group.total > length(group.items)}>
          <.link patch={category_path(group.category, @view.q)}>All {group.total}</.link>
        </:actions>
      </Kit.section_head>
      <Kit.entity_list label={label(group.category)}>
        <.row :for={item <- group.items} item={item} at={ShortTime.text(item.at, @now)} />
      </Kit.entity_list>
    </section>
    """
  end

  attr(:view, :map, required: true)
  attr(:today, :any, required: true)

  defp category_list(assigns) do
    assigns =
      assign(
        assigns,
        :groups,
        Kit.day_groups(assigns.view.items, & &1.at, DateTime.new!(assigns.today, ~T[23:59:59]))
      )

    ~H"""
    <Kit.entity_list :if={@view.items != []} label={label(@view.category)}>
      <.row
        :for={{item, group} <- Enum.zip(@view.items, @groups)}
        item={item}
        group={group}
        at={Kit.clock(item.at)}
      />
    </Kit.entity_list>
    <Kit.empty
      :if={@view.items == [] and @view.q != ""}
      icon={:search}
      title={"No #{String.downcase(label(@view.category))} feedback matches “#{@view.q}”"}
      text="Try other words, or clear the search to see all of it."
    />
    <Kit.empty
      :if={@view.items == [] and @view.q == ""}
      icon={:chat}
      title={"No #{String.downcase(label(@view.category))} feedback"}
      text={"When there is any, it shows here, newest first. " <> lede(@view.category)}
    />
    <.pager
      page={@view.page}
      pages={@view.pages}
      path={&page_path(@view, &1)}
      label="Feedback pages"
    />
    """
  end

  attr(:item, :map, required: true)
  attr(:at, :string, default: nil)
  attr(:group, :string, default: nil)

  defp row(assigns) do
    ~H"""
    <Kit.entity_row
      id={"feedback-signal-" <> @item.id}
      icon={icon(@item)}
      icon_tone={tile_tone(@item.category)}
      name={@item.request.title}
      href={@item.request.href}
      navigate
      state={state(@item)}
      text={text(@item)}
      meta={meta(@item)}
      at={@at}
      at_time={@item.at}
      group={@group}
    />
    """
  end

  # -- Words shared with the request's Feedback chapter --------------------------

  @doc "A category's name: Frustrated, Asked again, Edited or deleted, …"
  @spec label(atom()) :: String.t()
  def label(:frustrated), do: "Frustrated"
  def label(:asked_again), do: "Asked again"
  def label(:edited), do: "Edited or deleted"
  def label(:neutral), do: "Neutral"
  def label(:satisfied), do: "Satisfied"
  def label(:reviewed), do: "Reviewed"

  @doc "What a category holds, in one sentence."
  @spec lede(atom()) :: String.t()
  def lede(:frustrated),
    do: "People who were frustrated or angry with an answer, or reacted to say so."

  def lede(:asked_again),
    do: "The same person asked the same thing again within ten minutes of the answer."

  def lede(:edited), do: "People who changed or deleted their message after Ryker answered it."
  def lede(:neutral), do: "Reactions and replies that say neither way how an answer landed."
  def lede(:satisfied), do: "People who said or showed that an answer helped."
  def lede(:reviewed), do: "Your reviews of how requests ended, with your notes."

  @doc "A signal's state: a dot and a word, with what it means on hover."
  @spec state(map()) :: {atom(), String.t(), String.t()}
  def state(%{kind: :sentiment, value: feeling}) do
    {feeling_tone(feeling), String.capitalize(feeling),
     "How routing read their next message about this answer."}
  end

  def state(%{kind: :reaction_added, category: category}),
    do: {category_tone(category), label(category), "Read from the emoji they reacted with."}

  def state(%{kind: :reaction_removed}),
    do: {:off, "Took back", "They removed a reaction from Ryker's message."}

  def state(%{kind: :asked_again}),
    do:
      {:warn, "Asked again",
       "They asked the same thing again within ten minutes of Ryker's answer."}

  def state(%{kind: :message_edited}),
    do: {:warn, "Edited", "They changed their message after Ryker answered it."}

  def state(%{kind: :message_deleted}),
    do: {:warn, "Deleted", "They deleted their message after Ryker answered it."}

  def state(%{kind: :reviewed, value: ending}),
    do: {:off, "Reviewed", "Someone marked how this request #{ending_words(ending)} as reviewed."}

  @doc "What a signal is, as a card's heading on the request's Timeline."
  @spec title(map()) :: String.t()
  def title(%{kind: :sentiment}), do: "How they felt about the answer"
  def title(%{kind: :reaction_added, value: emoji}), do: "Reacted #{Emoji.glyph(emoji)}"
  def title(%{kind: :reaction_removed, value: emoji}), do: "Took back #{Emoji.glyph(emoji)}"
  def title(%{kind: :asked_again}), do: "Asked the same thing again"
  def title(%{kind: :message_edited}), do: "Edited their message after the answer"
  def title(%{kind: :message_deleted}), do: "Deleted their message after the answer"
  def title(%{kind: :reviewed}), do: "Ending reviewed"

  @doc "What a signal says, in a sentence: the reason or note, or what the person did."
  @spec text(map()) :: String.t() | nil
  def text(%{kind: :sentiment, note: note}) when is_binary(note), do: "“#{note}”"
  def text(%{kind: :sentiment}), do: "Routing read this from their next message."
  def text(%{kind: :reaction_added, value: emoji}), do: "Reacted #{Emoji.glyph(emoji)}"
  def text(%{kind: :reaction_removed, value: emoji}), do: "Took back #{Emoji.glyph(emoji)}"
  def text(%{kind: :asked_again}), do: "Asked the same thing again after the answer."
  def text(%{kind: :message_edited}), do: "Edited their message after Ryker answered it."
  def text(%{kind: :message_deleted}), do: "Deleted their message after Ryker answered it."
  def text(%{kind: :reviewed, note: note}) when is_binary(note), do: "“#{note}”"

  def text(%{kind: :reviewed, value: ending}),
    do: "Marked how the request #{ending_words(ending)} as reviewed."

  @doc "The icon a signal's tile carries: what kind of thing it is."
  @spec icon(map()) :: atom()
  def icon(%{kind: kind}) when kind in [:reaction_added, :reaction_removed], do: :smile
  def icon(%{kind: kind}) when kind in [:message_edited, :message_deleted], do: :pen
  def icon(%{kind: :reviewed}), do: :check
  def icon(%{kind: _sentiment_or_asked_again}), do: :chat

  defp ending_words("cancelled"), do: "was stopped"
  defp ending_words(_complete), do: "ended"

  defp feeling_tone(feeling) when feeling in ["frustrated", "angry"], do: :bad
  defp feeling_tone("satisfied"), do: :on
  defp feeling_tone(_neutral), do: :off

  defp category_tone(:frustrated), do: :bad
  defp category_tone(:satisfied), do: :on
  defp category_tone(_category), do: :off

  defp tile_tone(:frustrated), do: :bad
  defp tile_tone(category) when category in [:asked_again, :edited], do: :warn
  defp tile_tone(:satisfied), do: :accent
  defp tile_tone(:reviewed), do: :info
  defp tile_tone(_neutral), do: :off

  # Who gave it, where, and a way to the message it came from.
  defp meta(item) do
    [
      person(item.who),
      item.request.where,
      item.message_href && {:link, "Their message", item.message_href}
    ]
  end

  defp person(%{name: name, href: href}) when is_binary(href), do: {:link, name, href}
  defp person(%{name: name}), do: name

  # -- Counts and paths ------------------------------------------------------------

  # How much feedback the view lists, then how much of each kind, frustrated
  # first, each opening its own page.
  defp counts(%{category: nil} = view) do
    total = Kit.list_total(view.total, {"piece of feedback", "pieces of feedback"}, view.q != "")

    categories =
      for category <- FeedbackProjection.categories(),
          count = Map.get(view.counts, category, 0),
          count > 0 do
        %{
          value: count,
          label: String.downcase(label(category)),
          tone: count_tone(category),
          href: category_path(category, view.q)
        }
      end

    [total | categories]
  end

  defp counts(%{category: category} = view) do
    listed = Map.get(view, :listed, Map.get(view.counts, category, 0))
    [Kit.list_total(listed, {"piece of feedback", "pieces of feedback"}, view.q != "")]
  end

  # What there is to fix: how many are to decide, accepted and dismissed,
  # each opening its view of What to fix, then what went wrong with those
  # still to decide.
  defp fix_total(%{counts: counts}), do: counts |> Map.values() |> Enum.sum()
  defp fix_total(_none), do: 0

  defp fix_counts(%{counts: counts}) do
    decided =
      for {status, label} <- [accepted: "accepted", dismissed: "dismissed"],
          Map.fetch!(counts, status) > 0 do
        %{
          value: Map.fetch!(counts, status),
          label: label,
          href: ImprovementPage.view_path(status)
        }
      end

    [
      %{
        value: counts.open,
        label: "to decide",
        tone: if(counts.open > 0, do: :warn),
        href: ImprovementPage.view_path(:open)
      }
      | decided
    ]
  end

  defp fix_categories(%{categories: categories}) do
    for category <- Candidate.categories(),
        count = Map.get(categories, category, 0),
        count > 0 do
      %{
        value: count,
        label: String.downcase(Improvement.category_plural(category, count)),
        tone: if(category == :host_bug, do: :bad),
        href: ImprovementPage.view_path(:open, category)
      }
    end
  end

  defp count_tone(:frustrated), do: :bad
  defp count_tone(:asked_again), do: :warn
  defp count_tone(_category), do: nil

  # The table's columns: the kinds any shown day has, frustrated first.
  defp columns(days) do
    present = days |> Enum.flat_map(&Map.keys(&1.counts)) |> MapSet.new()
    Enum.filter(FeedbackProjection.categories(), &MapSet.member?(present, &1))
  end

  # A search on one category's page stays on that page.
  defp hidden(%{category: nil}), do: []
  defp hidden(%{category: category}), do: [{"category", Atom.to_string(category)}]

  defp category_path(category, ""), do: "#{@path}?category=#{category}"

  defp category_path(category, q),
    do: "#{@path}?" <> URI.encode_query(%{"category" => category, "q" => q})

  defp page_path(view, page) do
    "#{@path}?" <>
      URI.encode_query(
        %{"category" => view.category, "page" => page}
        |> Map.merge(if(view.q != "", do: %{"q" => view.q}, else: %{}))
      )
  end
end
