defmodule Ryker.ControlPlane.FindingCard do
  @moduledoc """
  A finding about a request a person was unhappy with: its card on What to
  fix, and its review on the request's timeline (Andrew approved the design,
  2026-10-15).

  It leads with the request and what went wrong, in the analysis's own words,
  with what Ryker should have done under it at the full width. The model's
  category is a suspected cause with its confidence, in the line under the
  title, never the headline: "Prompt bug" as a title read as a fact when the
  analysis was only medium sure. How the analysis ran is one Model run
  disclosure: the model and its attempts, the time, the tokens and cost, and
  the model's raw response. Attempt and worker IDs, fingerprints and receipts
  stay in the records, not on the card.
  """
  use Phoenix.Component
  alias Ryker.ControlPlane.{CallRun, Components}

  @doc """
  What the analysis made of a request and how sure it was, as the line under
  a finding's title says it: "Suspected cause: Ryker's instructions (medium
  confidence)".
  """
  @spec cause(atom() | nil, atom() | String.t() | nil) :: String.t() | nil
  def cause(nil, _confidence), do: nil
  def cause(category, confidence), do: words(category) <> sure(confidence)

  defp words(:host_bug), do: "Suspected cause: Ryker's code"
  defp words(:prompt_bug), do: "Suspected cause: Ryker's instructions"
  defp words(:model_mistake), do: "Suspected cause: a model mistake"
  defp words(:not_a_problem), do: "Likely not a problem"
  defp words(:unclear), do: "Cause unclear"

  defp sure(confidence) when confidence in [:high, :medium, :low],
    do: sure(Atom.to_string(confidence))

  defp sure(confidence) when confidence in ~w(high medium low), do: " (#{confidence} confidence)"
  defp sure(_confidence), do: ""

  @doc "What a category means, in one sentence: the hover text of a finding's cause."
  @spec hint(atom() | nil) :: String.t() | nil
  def hint(:host_bug) do
    "Ryker's own code let the model down: a tool was missing or failed, the context was wrong, or a good answer was mishandled."
  end

  def hint(:prompt_bug),
    do: "The model did what its instructions said, and they led it wrong or left something out."

  def hint(:model_mistake),
    do: "The instructions and context were enough; the model still got it wrong."

  def hint(:not_a_problem),
    do: "The answer was reasonable; the feedback was about something else."

  def hint(:unclear), do: "The evidence does not show what went wrong."
  def hint(_category), do: nil

  attr(:what_went_wrong, :string, default: nil)
  attr(:expected, :string, default: nil)
  attr(:note, :string, default: nil, doc: "Where the analysis stands, when it found nothing")

  @doc "What went wrong and what Ryker should have done, each at the full width."
  def body(assigns) do
    ~H"""
    <div :if={@what_went_wrong || @note || @expected} class="finding-body">
      <p :if={@what_went_wrong} class="finding-explanation">{@what_went_wrong}</p>
      <p :if={@note} class="finding-note">{@note}</p>
      <section :if={@expected} class="finding-expected">
        <h4>What Ryker should have done</h4>
        <p>{@expected}</p>
      </section>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:run, :map, required: true, doc: "`CallRun.t()` of the attempt the finding came from")
  attr(:attempts, :map, default: nil)
  attr(:response, :map, default: nil, doc: "%{text:, note:}: the raw response as it is shown")
  attr(:response_note, :string, default: nil, doc: "Why the raw response is not shown")

  @doc """
  How the analysis ran, closed until opened: its model and attempts, time,
  and tokens and cost, then the model's raw response.
  """
  def model_run(assigns) do
    ~H"""
    <Components.disclosure id={@id} label="Model run" class="finding-run">
      <:meta :if={CallRun.summary(@run)}>{CallRun.summary(@run)}</:meta>
      <CallRun.groups run={@run} attempts={@attempts} />
      <Components.json_disclosure
        :if={@response}
        id={@id <> "-response"}
        label="Raw model response"
        text={@response.text}
        note={@response[:note]}
      />
      <p :if={!@response && @response_note} class="artifact-unavailable">{@response_note}</p>
    </Components.disclosure>
    """
  end

  attr(:href, :string, required: true)
  attr(:label, :string, required: true)

  @doc "A link and its arrow as one link, with one underline."
  def arrow_link(assigns) do
    ~H"""
    <a href={@href} class="inline-link"><span>{@label} <span aria-hidden="true">→</span></span></a>
    """
  end

  attr(:request, :map, required: true)

  @doc """
  A self-analysis's result on the request's timeline: its review, built by
  `Ryker.ControlPlane.ImprovementRequests`.
  """
  def review(assigns) do
    assigns = assign(assigns, :review, assigns.request.review)

    ~H"""
    <div class="episode-request finding-review">
      <Components.card_heading title={@review.title}>
        <:detail :if={@review[:attempt]}>{@review.attempt}</:detail>
        <:description :if={@review[:meta]}>
          <span class="finding-cause" title={@review[:hint]}>{@review.meta}</span>
        </:description>
      </Components.card_heading>
      <p :if={@request[:retention_note]} class="artifact-unavailable request-retention">
        {@request.retention_note}
      </p>
      <.body
        what_went_wrong={@review[:what_went_wrong]}
        expected={@review[:expected]}
        note={@review[:note]}
      />
      <.model_run
        :if={@request[:run]}
        id={"#{@request.id}-run"}
        run={@request.run}
        attempts={@review[:attempts]}
        response={@review[:response]}
        response_note={@review[:response_note]}
      />
      <footer :if={@review[:finding_href]} class="finding-footer">
        <.arrow_link href={@review.finding_href} label="Review this finding" />
      </footer>
    </div>
    """
  end
end
