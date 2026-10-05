defmodule Ryker.ControlPlane.Evidence do
  @moduledoc """
  One meaning for the dimensions every evidence card repeats.

  Each card used to invent its own wording for the same questions, and the
  wordings disagreed. The expensive disagreement was always the same one:
  something nobody recorded rendered as a zero, and a zero reads as a checked,
  empty, healthy result. "0 rules matched" and "rule evaluation was not
  recorded" are opposite facts about whether anyone looked.

  The dimensions are applicability (whether it could apply at all),
  availability (whether the evidence is here to read), counts (over which scope
  and snapshot), and snapshot-versus-live.

  This module returns presentation descriptors, not HTML. Only render the
  dimensions a card actually has; the goal is consistent meaning, not eight
  badges per card.
  """

  @applicability_states ~w(not_applicable not_reached)a
  @availability_states ~w(recorded not_recorded unavailable redacted)a

  @type applicability_state :: :not_applicable | :not_reached
  @type availability_state :: :recorded | :not_recorded | :unavailable | :redacted

  @doc """
  Why a step did not apply: it could not apply at all, or it was never
  reached. They are different facts and each needs actual evidence; neither
  may be inferred from an absent row.
  """
  @spec applicability(applicability_state(), keyword()) :: map()
  def applicability(state, options \\ []) when state in @applicability_states do
    label =
      case state do
        :not_applicable -> "Not applicable"
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
        :unavailable -> "Unavailable"
        :redacted -> "Redacted"
      end

    %{
      dimension: :availability,
      state: state,
      label: label,
      known?: state == :recorded,
      tone: if(state == :unavailable, do: :warn),
      detail: detail(options)
    }
  end

  @doc """
  A count always carries its scope and its snapshot, so a reader never has to
  guess whether four means four in the workspace, four considered, or four in
  the visible page. An unknown count renders as the availability label and
  must not fall back to 0.
  """
  @spec count(non_neg_integer() | nil, keyword()) :: map()
  def count(value, options \\ [])

  def count(nil, options) do
    %{
      dimension: :count,
      value: nil,
      known?: false,
      label: availability(:not_recorded).label,
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

  defp detail(options), do: Keyword.get(options, :detail)
end
