defmodule Ryker.ControlPlane.BackgroundCards do
  @moduledoc """
  The parts learning's and the self-analysis's Timeline cards share
  (`Ryker.ControlPlane.LearningRequests`, `Ryker.ControlPlane.ImprovementRequests`):
  a background attempt is read from its own frozen record, so both build
  their sections, identity facts and model the same way.
  """
  alias Ryker.Accounting
  alias Ryker.InspectionRedactor, as: Redactor

  @max_bytes 2 * 1_024 * 1_024

  @doc "One section of a card: a titled, redacted artifact."
  @spec section(String.t(), String.t(), term(), atom(), keyword()) :: map()
  def section(id, title, value, source_kind, options),
    do: %{
      id: id,
      title: title,
      source_kind: source_kind,
      artifact_id: nil,
      artifact: Redactor.artifact(value, options)
    }

  @doc """
  The exact text an attempt was sent, as a card section: the stored bytes,
  never re-encoded, prepared only once a reader opens it when the page tracks
  what was opened.
  """
  @spec submitted(String.t() | nil, String.t(), atom(), map(), keyword()) :: map()
  def submitted(prompt, artifact_id, source_kind, context, options),
    do: %{
      id: "request",
      title: "Submitted prompt",
      source_kind: source_kind,
      artifact_id: artifact_id,
      artifact:
        Redactor.artifact(
          prompt,
          Keyword.merge(options,
            preserve_format: true,
            disclosed: disclosed?(context.disclosed, artifact_id)
          )
        )
    }

  @doc "How an attempt's artifacts are read: redacted, bounded, and marked expired once pruned."
  @spec artifact_options(map(), map()) :: keyword()
  def artifact_options(run, context),
    do: [
      secrets: context.secrets,
      max_bytes: @max_bytes,
      expired: not is_nil(Map.get(run, :pruned_at))
    ]

  defp disclosed?(%MapSet{} = disclosed, id), do: MapSet.member?(disclosed, id)
  defp disclosed?(_no_disclosure_tracking, _id), do: true

  @doc """
  The model and effort the worker ran, as its report named them; the
  attempt's own record keeps it only until retention.
  """
  @spec target(map(), Accounting.Execution.t() | nil) :: String.t() | nil
  def target(_run, %Accounting.Execution{execution_target: target}) when is_binary(target),
    do: target

  def target(run, _execution), do: get_in(run.producer || %{}, ["target"])

  @doc "The attempt's receipts exactly as recorded, redacted like every other artifact."
  @spec record_text(map(), list()) :: String.t() | nil
  def record_text(record, secrets) do
    text = Redactor.artifact(record, secrets: secrets).text

    case Jason.decode(text || "") do
      {:ok, value} -> Jason.encode!(value, pretty: true)
      _unreadable -> text
    end
  end

  @doc "An identity fact, or nil when the value is absent."
  @spec identifier(String.t(), term()) :: map() | nil
  def identifier(_label, nil), do: nil
  def identifier(label, value), do: %{label: label, value: value, identifier: true}

  @doc "A time fact to the second, or nil when the time is absent."
  @spec time(String.t(), DateTime.t() | nil) :: map() | nil
  def time(_label, nil), do: nil

  def time(label, %DateTime{} = at),
    do: %{label: label, value: Calendar.strftime(at, "%d %b %Y, %H:%M:%S UTC")}

  @doc "A time in a sentence, to the minute."
  @spec timestamp(DateTime.t()) :: String.t()
  def timestamp(at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")

  @doc "Trimmed text, or nil when there is none."
  @spec present(term()) :: String.t() | nil
  def present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def present(_value), do: nil

  @doc "A stored JSON document as a map; anything unreadable is an empty one."
  @spec decode(term()) :: map()
  def decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = document} -> document
      _unreadable -> %{}
    end
  end

  def decode(_value), do: %{}
end
