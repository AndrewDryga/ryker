defmodule Ryker.ControlPlane.ImprovementPage do
  @moduledoc """
  Feedback › What to fix (`/feedback/fix`): requests people
  were unhappy with, each with Ryker's own diagnosis of what went wrong
  (`Ryker.Improvement`, `Ryker.ControlPlane.ImprovementProjection`).

  Andrew, 2026-09-27: "do something about it (at very least see where users
  were frustrated to see what happened and fix the issue). Ideally, we need
  evals building based on sentiment and self-analysis without much of manual
  human reviews." A person only decides: accept a diagnosis as an eval case,
  or dismiss it. Both ask first in `Kit.confirm_modal/1`, and either can be
  changed later from the Accepted and Dismissed views. Accepted cases
  download as world scenarios from the button opposite the title.

  Each request is one finding card (`Ryker.ControlPlane.FindingCard`, the
  design Andrew approved 2026-10-15): the request and what went wrong at the
  full width, what Ryker should have done, the suspected cause and how sure
  the analysis was in the line under the title, how the analysis ran behind
  Model run, and the decision in the card's footer. The three decisions are
  tabs with their counts, said once. The page redraws as candidates are
  found, analyzed or decided (`subscriptions/0`).
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components, only: [action_button: 1, pager: 1]
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.FindingCard
  alias Ryker.ControlPlane.Kit
  alias Ryker.ControlPlane.Paths
  alias Ryker.ControlPlane.ShortTime
  alias Ryker.Improvement

  @path "/feedback/fix"
  @download "/feedback/fix/eval-cases.zip"
  @missing ~w(improvement_evidence_unavailable improvement_evidence_wordless
    improvement_evidence_automated)

  @doc "The page's own address."
  def path, do: @path

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
      description: "Review what went wrong. Keep useful findings as eval cases, or dismiss them.",
      back: {"All feedback", "/feedback"},
      action:
        if view.exportable > 0 do
          ~s(<a class="ui-button secondary" href="#{@download}" download>Download eval cases</a>)
        end
    }
  end

  @doc "The page body for an `ImprovementProjection.page/1` view."
  @spec html(map()) :: iodata()
  def html(view), do: %{__changed__: nil, view: view} |> render() |> Safe.to_iodata()

  defp render(assigns) do
    ~H"""
    <div class="memory-view memory-improvement">
      <Kit.tabs label="Decision" options={tabs(@view)} />
      <p :if={@view.category} class="finding-filter">
        {@view.listed} {String.downcase(Improvement.category_plural(@view.category, @view.listed))} ·
        <a href={view_path(@view.status)}>Show all</a>
      </p>
      <section :if={@view.items != []} class="findings" aria-label="Requests to improve">
        <.finding :for={item <- @view.items} item={item} now={DateTime.utc_now()} />
      </section>
      <Kit.empty
        :if={@view.items == [] and is_nil(@view.category)}
        icon={:check}
        title={empty_title(@view.status)}
        text={empty_text(@view.status)}
      />
      <Kit.empty
        :if={@view.items == [] and @view.category}
        icon={:search}
        title={"No #{String.downcase(Improvement.category_label(@view.category))} here"}
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
  attr(:now, :any, required: true)

  defp finding(assigns) do
    item = assigns.item

    assigns =
      assign(assigns,
        accept: item.status in [:open, :dismissed] and acceptable?(item),
        dismiss: item.status in [:open, :accepted],
        state: state(item),
        feedback: reasons(item.reasons)
      )

    ~H"""
    <article
      class="finding"
      id={"improvement-" <> @item.id}
      aria-labelledby={"improvement-#{@item.id}-title"}
    >
      <header class="finding-header">
        <h3 id={"improvement-#{@item.id}-title"}>{@item.request.title}</h3>
        <p class="finding-meta">
          <time datetime={ShortTime.iso(@item.at)}>{ShortTime.stamp(@item.at, @now)}</time>
          <span :if={@feedback}>Feedback: {@feedback}</span>
          <span :if={@item.request[:where]}>{@item.request.where}</span>
          <span class="finding-cause" title={@state.hint}>{@state.cause}</span>
        </p>
      </header>
      <FindingCard.body
        what_went_wrong={@state.text}
        expected={@item.expected}
        note={@state.note}
      />
      <FindingCard.model_run
        :if={@item.analysis_run}
        id={"improvement-#{@item.id}-run"}
        run={@item.analysis_run.run}
        attempts={@item.analysis_run.attempts}
        response={@item.analysis_run.response}
        response_note={@item.analysis_run.response_note}
      />
      <footer class="finding-footer">
        <FindingCard.arrow_link
          :if={@item.request[:href]}
          href={@item.request.href}
          label="Open request timeline"
        />
        <div class="finding-actions">
          <p :if={not Improvement.replayable?(@item)} class="finding-unsupported">
            {unsupported(@item)}
          </p>
          <.action_button
            :if={@dismiss}
            path={Paths.action("improvement", @item.id, "dismiss")}
            label="Dismiss"
          />
          <.action_button
            :if={@accept}
            path={Paths.action("improvement", @item.id, "accept")}
            label="Accept as eval case"
            tone={:primary}
          />
        </div>
      </footer>
    </article>
    """
  end

  @doc """
  Whether a request can be accepted as an eval case: Ryker found the
  person's words (`Ryker.Improvement.Evidence.gather/1`), from a place a
  world scenario replays (`Ryker.Improvement.replayable?/1`).
  """
  @spec acceptable?(map()) :: boolean()
  def acceptable?(%{analysis: :failed, error_code: code}) when code in @missing, do: false
  def acceptable?(item), do: Improvement.replayable?(item)

  defp unsupported(%{transport: "github"}),
    do: "GitHub requests cannot be kept as eval cases yet."

  defp unsupported(_item), do: "Requests from here cannot be kept as eval cases yet."

  # -- Words -----------------------------------------------------------------------

  # Where a candidate's analysis stands: the cause it found and how sure it
  # was, with what went wrong in its words; or why there is none yet.
  defp state(%{analysis: :done, category: category, confidence: confidence} = item),
    do: %{
      cause: FindingCard.cause(category, confidence),
      hint: FindingCard.hint(category),
      text: item.what_went_wrong,
      note: nil
    }

  defp state(%{analysis: :running}),
    do: unanalyzed("Analyzing", "Ryker is asking the learning models what went wrong.")

  defp state(%{analysis: :failed, error_code: code}),
    do: unanalyzed("Not analyzed", failure(code))

  defp state(%{status: :dismissed}),
    do: unanalyzed("Not analyzed", "It was dismissed before Ryker analyzed it.")

  defp state(%{analysis: :pending}) do
    unanalyzed(
      "Waiting to be analyzed",
      "Ryker analyzes it once the request is done and a few minutes pass without new feedback, while learning is on."
    )
  end

  defp unanalyzed(cause, note), do: %{cause: cause, hint: nil, text: nil, note: note}

  defp failure("improvement_evidence_unavailable"),
    do: "The person's messages were deleted or have expired, so there was nothing to analyze."

  defp failure("improvement_evidence_wordless") do
    "The person's messages had no words Ryker can read, such as a file, an image or a review sent without any, so there was nothing to analyze."
  end

  defp failure("improvement_evidence_automated") do
    "No person asked for it: an alert, a schedule or an app's message started it, so there were no person's words to analyze."
  end

  defp failure("improvement_retry_exhausted"),
    do: "Ryker tried three times and got no usable answer from the learning models."

  defp failure(_code), do: "The analysis did not finish."

  # What people did, in words: frustrated, asked again, …
  defp reasons([]), do: nil

  defp reasons(reasons) do
    reasons
    |> Enum.sort_by(&Enum.find_index(Ryker.Improvement.reasons(), fn reason -> reason == &1 end))
    |> Enum.map_join(", ", &reason/1)
  end

  defp reason("frustrated"), do: "frustrated"
  defp reason("reaction"), do: "reacted with a thumbs down"
  defp reason("asked_again"), do: "asked again"
  defp reason("edited"), do: "changed their message"
  defp reason("rated"), do: "a person rated it as needing work"
  defp reason(other), do: other

  # -- Views and paths -------------------------------------------------------------

  # The three decisions, each with how many it holds; the counts are said
  # here and nowhere else on the page.
  defp tabs(view) do
    for {status, label} <- [open: "To decide", accepted: "Accepted", dismissed: "Dismissed"] do
      %{
        label: label,
        count: Map.fetch!(view.counts, status),
        href: view_path(status),
        current: view.status == status
      }
    end
  end

  @doc "The page for one decision, and optionally one category."
  @spec view_path(atom(), atom() | nil) :: String.t()
  def view_path(status, category \\ nil)
  def view_path(:open, nil), do: @path
  def view_path(status, nil), do: "#{@path}?status=#{status}"

  def view_path(status, category),
    do: Paths.query(@path, %{"status" => status, "category" => category})

  defp page_path(view, page) do
    query =
      [
        {"status", view.status != :open && view.status},
        {"category", view.category},
        {"page", page}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    Paths.query(@path, query)
  end

  defp empty_title(:open), do: "Nothing to decide"
  defp empty_title(:accepted), do: "No eval cases yet"
  defp empty_title(:dismissed), do: "Nothing dismissed"

  defp empty_text(:open) do
    "When someone is frustrated with an answer, reacts with a thumbs down, asks again or changes their message after it, the request shows here with what Ryker thinks went wrong."
  end

  defp empty_text(:accepted),
    do: "Accept a request to keep it as an eval case you can download for testdata."

  defp empty_text(:dismissed), do: "Dismissed requests stay here, so you can accept one later."
end
