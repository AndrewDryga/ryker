defmodule Ryker.ControlPlane.ImprovementPage do
  @moduledoc """
  Memory › Feedback › What to fix (`/memory/feedback/fix`): requests people
  were unhappy with, each with Ryker's own diagnosis of what went wrong
  (`Ryker.Improvement`, `Ryker.ControlPlane.ImprovementProjection`).

  Andrew, 2026-09-27: "do something about it (at very least see where users
  were frustrated to see what happened and fix the issue). Ideally, we need
  evals building based on sentiment and self-analysis without much of manual
  human reviews." A person only decides: accept a diagnosis as an eval case,
  or dismiss it. Both ask first in `Kit.confirm_modal/1`, and either can be
  changed later from the Accepted and Dismissed views. Accepted cases
  download as world scenarios from the button opposite the title.

  Everything here is a Kit part: the counts, the view switch, day-headed rows
  with their state beside the name, the expectation as a fact under each row,
  and empty states. The page redraws as candidates are found, analyzed or
  decided (`subscriptions/0`).
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [action_button: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.Kit
  alias Ryker.Improvement.Candidate

  @path "/memory/feedback/fix"
  @download "/memory/feedback/fix/eval-cases.zip"

  @doc "The page's own address."
  def path, do: @path

  @doc "Where accepted cases download from."
  def download_path, do: @download

  @doc """
  The topics an open What to fix page listens to: candidates found,
  analyzed or decided, and new feedback on them.
  """
  def subscriptions,
    do: [
      {Ryker.Improvement, :subscribe_improvement, []},
      {Ryker.Feedback, :subscribe_feedback, []}
    ]

  @doc """
  The shell's heading for the page: its title and sentence, the way back to
  all feedback, and the download of accepted cases opposite the title once
  there is one.
  """
  @spec heading(map()) :: map()
  def heading(view) do
    %{
      title: "What to fix",
      description:
        "Requests people were unhappy with, each with Ryker's own diagnosis. Accept one to keep it as an eval case, or dismiss it.",
      back: {"All feedback", "/memory/feedback"},
      action:
        if(view.exportable > 0,
          do:
            ~s(<a class="ui-button secondary" href="#{@download}" download>Download eval cases</a>)
        )
    }
  end

  @doc "The page body for an `ImprovementProjection.page/1` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  def render(assigns) do
    assigns =
      assign(assigns, :groups, Kit.day_groups(assigns.view.items, & &1.at, DateTime.utc_now()))

    ~H"""
    <div class="memory-view memory-improvement">
      <Kit.counts label="What to fix" items={counts(@view)} />
      <Kit.toolbar>
        <Kit.segmented label="Decision" options={views(@view)} />
      </Kit.toolbar>
      <Kit.counts
        :if={@view.categories != %{}}
        label="What went wrong"
        secondary
        items={category_counts(@view)}
      />
      <Kit.entity_list :if={@view.items != []} label="Requests to improve">
        <.row :for={{item, group} <- Enum.zip(@view.items, @groups)} item={item} group={group} />
      </Kit.entity_list>
      <Kit.empty
        :if={@view.items == [] and is_nil(@view.category)}
        icon={:check}
        title={empty_title(@view.status)}
        text={empty_text(@view.status)}
      />
      <Kit.empty
        :if={@view.items == [] and @view.category}
        icon={:search}
        title={"No #{String.downcase(category_label(@view.category))} here"}
        text="Choose another kind of problem, or all of them from the view above."
      />
      <.pager
        page={@view.page}
        pages={@view.pages}
        path={&page_path(@view, &1)}
        label="Pages of requests to improve"
      />
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:group, :string, default: nil)

  defp row(assigns) do
    ~H"""
    <Kit.entity_row
      id={"improvement-" <> @item.id}
      icon={icon(@item)}
      icon_tone={tone(@item)}
      name={@item.request.title}
      href={@item.request.href}
      navigate
      state={state(@item)}
      state_by_name
      text={text(@item)}
      meta={meta(@item)}
      at={Kit.clock(@item.at)}
      at_time={@item.at}
      group={@group}
    >
      <:details :if={@item.expected}>
        <Kit.facts facts={[{"Ryker should have", @item.expected}]} />
      </:details>
      <:actions>
        <.action_button
          :if={@item.status in [:open, :dismissed]}
          path={action_path(@item.id, "accept")}
          label="Accept as eval case"
        />
        <.action_button
          :if={@item.status in [:open, :accepted]}
          path={action_path(@item.id, "dismiss")}
          label="Dismiss"
        />
      </:actions>
    </Kit.entity_row>
    """
  end

  # -- Words -----------------------------------------------------------------------

  @doc "A category's name: Host bug, Prompt bug, …"
  @spec category_label(atom()) :: String.t()
  def category_label(:host_bug), do: "Host bug"
  def category_label(:prompt_bug), do: "Prompt bug"
  def category_label(:model_mistake), do: "Model mistake"
  def category_label(:not_a_problem), do: "Not a problem"
  def category_label(:unclear), do: "Unclear"

  @doc "What a category means, in one sentence."
  @spec category_hint(atom()) :: String.t()
  def category_hint(:host_bug),
    do:
      "Ryker's own code let the model down: a tool was missing or failed, the context was wrong, or a good answer was mishandled."

  def category_hint(:prompt_bug),
    do: "The model did what its instructions said, and they led it wrong or left something out."

  def category_hint(:model_mistake),
    do: "The instructions and context were enough; the model still got it wrong."

  def category_hint(:not_a_problem),
    do: "The answer was reasonable; the feedback was about something else."

  def category_hint(:unclear), do: "The evidence does not show what went wrong."

  @doc "A candidate's state: its diagnosis, or where its analysis stands."
  @spec state(map()) :: {atom(), String.t(), String.t()}
  def state(%{analysis: :done, category: category}) do
    tone =
      case category do
        :host_bug -> :bad
        category when category in [:prompt_bug, :model_mistake] -> :warn
        _other -> :off
      end

    {tone, category_label(category), category_hint(category)}
  end

  def state(%{analysis: :running}),
    do: {:busy, "Analyzing", "Ryker is asking the learning models what went wrong."}

  def state(%{analysis: :failed, error_code: code}),
    do: {:warn, "Not analyzed", failure(code)}

  def state(%{status: :dismissed}),
    do: {:off, "Not analyzed", "It was dismissed before Ryker analyzed it."}

  def state(%{analysis: :pending}),
    do:
      {:off, "Waiting",
       "Ryker analyzes it once the request is done and a few minutes pass without new feedback, while learning is on."}

  defp failure("improvement_evidence_unavailable"),
    do: "The person's messages were deleted or have expired, so there was nothing to analyze."

  defp failure("improvement_retry_exhausted"),
    do: "Ryker tried three times and got no usable answer from the learning models."

  defp failure(_code), do: "The analysis did not finish."

  defp text(%{analysis: :done, what_went_wrong: text}) when is_binary(text), do: text
  defp text(_item), do: nil

  defp icon(%{analysis: :done, category: :host_bug}), do: :code
  defp icon(%{analysis: :done, category: :prompt_bug}), do: :pen
  defp icon(%{analysis: :done, category: :model_mistake}), do: :bolt
  defp icon(%{analysis: :done, category: :not_a_problem}), do: :check
  defp icon(%{analysis: :done}), do: :help
  defp icon(%{analysis: :failed}), do: :incident
  defp icon(_item), do: :clock

  defp tone(%{analysis: :done, category: :host_bug}), do: :bad

  defp tone(%{analysis: :done, category: category})
       when category in [:prompt_bug, :model_mistake],
       do: :warn

  defp tone(%{analysis: :failed}), do: :warn
  defp tone(%{analysis: :running}), do: :info
  defp tone(_item), do: :off

  # Where it went wrong, how sure Ryker is, what people did, and where.
  defp meta(item) do
    [
      step(item.step),
      item.confidence && "#{String.capitalize(Atom.to_string(item.confidence))} confidence",
      reasons(item.reasons),
      item.request.where
    ]
  end

  defp step(:routing), do: "At routing"
  defp step(:work), do: "In Work"
  defp step(:delivery), do: "At delivery"
  defp step(nil), do: nil

  @doc "What people did, in words: Frustrated, asked again, …"
  @spec reasons([String.t()]) :: String.t() | nil
  def reasons([]), do: nil

  def reasons(reasons) do
    reasons
    |> Enum.sort_by(&Enum.find_index(Ryker.Improvement.reasons(), fn reason -> reason == &1 end))
    |> Enum.map_join(", ", &reason/1)
    |> String.capitalize()
  end

  defp reason("frustrated"), do: "frustrated"
  defp reason("reaction"), do: "reacted with a thumbs down"
  defp reason("asked_again"), do: "asked again"
  defp reason("edited"), do: "changed their message"
  defp reason("stopped"), do: "the request was stopped"
  defp reason(other), do: other

  # -- Counts, views and paths --------------------------------------------------------

  # How many of each decision, the one shown first: to decide, accepted,
  # dismissed, each opening its own view.
  defp counts(view) do
    total =
      Kit.list_total(
        if(view.category, do: view.listed, else: Map.fetch!(view.counts, view.status)),
        count_nouns(view.status),
        not is_nil(view.category)
      )

    others =
      for status <- [:open, :accepted, :dismissed],
          status != view.status,
          count = Map.fetch!(view.counts, status),
          count > 0 do
        %{
          value: count,
          label: status_word(status),
          tone: if(status == :open, do: :warn),
          href: view_path(status)
        }
      end

    [total | others]
  end

  defp count_nouns(:open), do: {"to decide", "to decide"}
  defp count_nouns(:accepted), do: {"accepted eval case", "accepted eval cases"}
  defp count_nouns(:dismissed), do: {"dismissed", "dismissed"}

  defp status_word(:open), do: "to decide"
  defp status_word(:accepted), do: "accepted"
  defp status_word(:dismissed), do: "dismissed"

  defp views(view) do
    for {status, label} <- [open: "To decide", accepted: "Accepted", dismissed: "Dismissed"] do
      {label, view_path(status), view.status == status and is_nil(view.category)}
    end
  end

  # How what the view shows splits by what went wrong, each narrowing to it.
  defp category_counts(view) do
    for category <- Candidate.categories(),
        count = Map.get(view.categories, category, 0),
        count > 0 do
      %{
        value: count,
        label: String.downcase(category_plural(category, count)),
        tone: if(category == :host_bug, do: :bad),
        href: view_path(view.status, category)
      }
    end
  end

  @doc "A category's name for a count of them: 2 prompt bugs, 1 host bug, 3 unclear."
  @spec category_plural(atom(), non_neg_integer()) :: String.t()
  def category_plural(category, 1), do: category_label(category)
  def category_plural(:not_a_problem, _count), do: "Not a problem"
  def category_plural(:unclear, _count), do: "Unclear"
  def category_plural(category, _count), do: category_label(category) <> "s"

  @doc "The page for one decision, and optionally one category."
  @spec view_path(atom(), atom() | nil) :: String.t()
  def view_path(status, category \\ nil)
  def view_path(:open, nil), do: @path
  def view_path(status, nil), do: "#{@path}?status=#{status}"

  def view_path(status, category),
    do: "#{@path}?" <> URI.encode_query(%{"status" => status, "category" => category})

  defp page_path(view, page) do
    query =
      [
        {"status", view.status != :open && view.status},
        {"category", view.category},
        {"page", page}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    "#{@path}?" <> URI.encode_query(query)
  end

  defp action_path(id, action), do: "/actions/improvement/#{id}/#{action}"

  defp empty_title(:open), do: "Nothing to decide"
  defp empty_title(:accepted), do: "No eval cases yet"
  defp empty_title(:dismissed), do: "Nothing dismissed"

  defp empty_text(:open),
    do:
      "When someone is frustrated with an answer, reacts with a thumbs down, asks again or changes their message after it, the request shows here with what Ryker thinks went wrong."

  defp empty_text(:accepted),
    do: "Accept a request to keep it as an eval case you can download for testdata."

  defp empty_text(:dismissed), do: "Dismissed requests stay here, so you can accept one later."
end
