defmodule Ryker.ControlPlane.Evidence do
  @moduledoc """
  One meaning for the dimensions every evidence card repeats.

  Each card used to invent its own wording for the same six questions, and the
  wordings disagreed. The expensive disagreement was always the same one:
  something nobody recorded rendered as a zero, and a zero reads as a checked,
  empty, healthy result. "0 rules matched" and "rule evaluation was not
  recorded" are opposite facts about whether anyone looked.

  The dimensions are execution (what happened to this exact operation),
  applicability (whether it could apply at all), availability (whether the
  evidence is here to read), counts (over which scope and snapshot),
  snapshot-versus-live, the captured prompt boundary, and safe exactness.

  This module returns presentation descriptors, not HTML. Only render the
  dimensions a card actually has; the goal is consistent meaning, not eight
  badges per card.
  """

  @execution_states ~w(queued running completed failed cancelled)a
  @applicability_states ~w(applies not_applicable skipped not_reached)a
  @availability_states ~w(recorded not_recorded upstream_elided loading unavailable expired redacted)a

  @type execution_state :: :queued | :running | :completed | :failed | :cancelled
  @type applicability_state :: :applies | :not_applicable | :skipped | :not_reached
  @type availability_state ::
          :recorded
          | :not_recorded
          | :upstream_elided
          | :loading
          | :unavailable
          | :expired
          | :redacted

  @doc """
  What happened to this exact operation. Never a verdict about correctness:
  a completed model call that produced a rejected answer is still completed.
  """
  @spec execution(execution_state(), keyword()) :: map()
  def execution(state, options \\ []) when state in @execution_states do
    {label, tone} =
      case state do
        :queued -> {"Queued", nil}
        :running -> {"Running", nil}
        :completed -> {"Completed", :good}
        :failed -> {"Failed", :bad}
        :cancelled -> {"Cancelled", nil}
      end

    %{
      dimension: :execution,
      state: state,
      label: label,
      tone: tone,
      detail: detail(options),
      # A success icon carries the state. Repeating "Passed" beside a green tick
      # is the same fact twice and crowds out the reasons that are not obvious.
      icon_only: state == :completed
    }
  end

  @doc """
  Whether this step could apply at all. Not applicable, deliberately skipped
  and never reached are three different facts and each needs actual evidence;
  none of them may be inferred from an absent row.
  """
  @spec applicability(applicability_state(), keyword()) :: map()
  def applicability(state, options \\ []) when state in @applicability_states do
    label =
      case state do
        :applies -> "Applies"
        :not_applicable -> "Not applicable"
        :skipped -> "Skipped"
        :not_reached -> "Not reached"
      end

    %{
      dimension: :applicability,
      state: state,
      label: label,
      # A neutral non-match is ordinary information, not an error.
      tone: nil,
      detail: detail(options)
    }
  end

  @doc """
  Whether the evidence is here to read. Every state except `:recorded` means
  the reader is looking at an absence, and an absence is never a zero, a
  failure verdict, or a check that passed.
  """
  @spec availability(availability_state(), keyword()) :: map()
  def availability(state, options \\ []) when state in @availability_states do
    label =
      case state do
        :recorded -> "Recorded"
        :not_recorded -> "Not recorded"
        :upstream_elided -> "Elided by the source"
        :loading -> "Loading"
        :unavailable -> "Unavailable"
        :expired -> "Expired"
        :redacted -> "Redacted"
      end

    %{
      dimension: :availability,
      state: state,
      label: label,
      known?: state == :recorded,
      tone: if(state in [:unavailable, :expired], do: :warn),
      detail: detail(options)
    }
  end

  @doc "True only when the evidence is actually present and may be counted."
  @spec known?(availability_state()) :: boolean()
  def known?(state) when state in @availability_states, do: state == :recorded

  @doc """
  A count always carries its scope and its snapshot, so a reader never has to
  guess whether four means four in the workspace, four considered, or four in
  the visible page. An unknown count renders as the availability label and
  must not fall back to 0.
  """
  @spec count(non_neg_integer() | nil, keyword()) :: map()
  def count(value, options \\ [])

  def count(nil, options) do
    availability = Keyword.get(options, :availability, :not_recorded)

    %{
      dimension: :count,
      value: nil,
      known?: false,
      label: availability(availability, options).label,
      scope: Keyword.get(options, :scope),
      snapshot: Keyword.get(options, :snapshot, :historical)
    }
  end

  def count(value, options) when is_integer(value) and value >= 0 do
    %{
      dimension: :count,
      value: value,
      known?: true,
      label: Integer.to_string(value),
      scope: Keyword.get(options, :scope),
      snapshot: Keyword.get(options, :snapshot, :historical)
    }
  end

  @doc """
  Eligible = included + omitted, and only when both come from the same complete
  disjoint set. Shortening is a property of content that *was* included, so a
  shortened partial is never also an omitted one; counting it twice invented
  omissions that nobody recorded.

  Returns `:unknown` for `eligible` when the complete set was not recorded.
  """
  @spec selection(keyword()) :: map()
  def selection(options) do
    included = Keyword.get(options, :included)
    omitted = Keyword.get(options, :omitted)
    shortened = Keyword.get(options, :shortened, 0)
    complete? = Keyword.get(options, :complete_set, true)

    eligible =
      if complete? and is_integer(included) and is_integer(omitted),
        do: included + omitted,
        else: nil

    %{
      dimension: :selection,
      eligible: count(eligible, scope: Keyword.get(options, :scope)),
      included: count(included, scope: Keyword.get(options, :scope)),
      omitted: count(omitted, scope: Keyword.get(options, :scope)),
      shortened: count(shortened, scope: :included),
      complete_set: complete?
    }
  end

  @doc """
  Historical preparation stays frozen at the moment it was captured. Anything
  read from a live source is explicitly current and carries the time it was
  observed, so a later failed lookup never silently overwrites earlier evidence.
  """
  @spec snapshot(:historical | :current, keyword()) :: map()
  def snapshot(kind, options \\ []) when kind in [:historical, :current] do
    observed_at = Keyword.get(options, :observed_at)

    %{
      dimension: :snapshot,
      kind: kind,
      observed_at: observed_at,
      label:
        case {kind, observed_at} do
          {:historical, _} -> "As recorded"
          {:current, nil} -> "Current"
          {:current, _at} -> "Current as of"
        end
    }
  end

  @doc """
  Names the captured boundary of a full prompt. A Ryker submission is what
  Ryker froze and sent; it is not automatically the provider's entire
  assembled request, and worker-added instructions are never invented here.
  """
  @spec prompt_boundary(:ryker_submission | :provider_request | :not_recorded) :: map()
  def prompt_boundary(boundary)
      when boundary in [:ryker_submission, :provider_request, :not_recorded] do
    label =
      case boundary do
        :ryker_submission -> "Submitted by Ryker"
        :provider_request -> "Assembled by the provider"
        :not_recorded -> "Prompt boundary not recorded"
      end

    %{
      dimension: :prompt_boundary,
      boundary: boundary,
      label: label,
      detail:
        case boundary do
          :ryker_submission ->
            "Exactly what Ryker froze and sent. A worker may add its own instructions; those are not captured here."

          :provider_request ->
            "The assembled request as the provider received it."

          :not_recorded ->
            "Which boundary this text came from was not recorded."
        end
    }
  end

  @doc """
  Describes a redacted artifact honestly. Copy copies the displayed safe view,
  so the original size and digest are labelled as the *original's* — never as
  a checksum of what is on screen. Source highlighting is preserved without
  claiming the redacted bytes are the original bytes.
  """
  @spec safe_artifact(map()) :: map()
  def safe_artifact(artifact) when is_map(artifact) do
    altered? = Map.get(artifact, :redacted, false) or Map.get(artifact, :truncated, false)

    %{
      dimension: :safe_artifact,
      availability: availability(artifact_availability(artifact)),
      altered?: altered?,
      copies: :displayed_safe_view,
      original_bytes: Map.get(artifact, :original_bytes),
      original_digest: Map.get(artifact, :original_digest),
      original_label: "Original (before safe display)",
      note:
        if(altered?,
          do:
            "The displayed text was made safe for inspection. Size and digest describe the original, not this display."
        )
    }
  end

  defp artifact_availability(%{state: :retained} = artifact) do
    if Map.get(artifact, :redacted, false), do: :redacted, else: :recorded
  end

  defp artifact_availability(%{state: :expired}), do: :expired
  defp artifact_availability(%{state: :absent}), do: :not_recorded
  defp artifact_availability(%{state: state}) when state in @availability_states, do: state
  defp artifact_availability(_artifact), do: :not_recorded

  defp detail(options), do: Keyword.get(options, :detail)
end
