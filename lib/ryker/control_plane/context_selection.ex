defmodule Ryker.ControlPlane.ContextSelection do
  @moduledoc """
  What Ryker chose to send one Work turn, and what it left out, in plain words.

  The selection ledger is Ryker's own record of preparing the turn, not part
  of the prompt, so it is a card of its own before the Work briefing. The
  briefing shows exactly what was sent; this card says what else existed and
  why it was not sent.
  """

  @listed [
    {"observations", "Source notes"},
    {"knowledge", "Saved topics"},
    {"records", "Records"},
    {"related_outcomes", "Related outcomes"},
    {"guidance", "Guidance"},
    {"memory", "Memory"},
    {"standing_assignments", "Rules"}
  ]

  @doc "The card's content for a turn's selection ledger, or nil when none was recorded."
  @spec present(map() | nil, map() | nil) :: map() | nil
  def present(%{"inputs" => %{} = inputs} = ledger, context) do
    %{
      summary: summary(ledger["mode"], inputs, context),
      facts:
        Enum.reject(
          [{"Messages", messages(ledger["mode"], inputs, context)}] ++
            listed(ledger) ++ [{"Limits", limits(ledger["limits"])}],
          &is_nil(elem(&1, 1))
        ),
      record: Jason.encode!(ledger, pretty: true),
      record_label: "Selection record"
    }
  end

  def present(_ledger, _context), do: nil

  defp summary("continuation", inputs, _context),
    do: "Continues the session · #{plural(integer(inputs["current"]), "new message")}"

  defp summary(_mode, %{"eligible" => eligible} = inputs, context) when is_integer(eligible) do
    sent = integer(inputs["current"]) + earlier_sent(inputs, context)
    "#{sent} of #{plural(eligible, "message")} sent"
  end

  defp summary(_mode, _inputs, _context), do: nil

  defp messages("continuation", inputs, _context) do
    [
      count(inputs["current"], "new"),
      positive(inputs["earlier_not_resent"], &"#{&1} earlier already in the session")
    ]
    |> join()
  end

  defp messages(_mode, inputs, context) do
    [
      count(inputs["current"], "current"),
      positive(earlier_sent(inputs, context), &"#{&1} earlier sent"),
      positive(inputs["omitted_window"], &"#{&1} outside the history window"),
      positive(inputs["omitted_fit"], &"#{&1} cut to fit")
    ]
    |> join()
  end

  # What was sent is counted from the frozen request, which is the exact set
  # that reached the model; the ledger's own figure is only a fallback.
  defp earlier_sent(_inputs, %{"inputs" => %{"items" => items}}) when is_list(items),
    do: Enum.count(items, &(not (is_map(&1) and &1["current"] == true)))

  defp earlier_sent(inputs, _context), do: integer(inputs["earlier_included"])

  # Only kinds where something existed but was not sent; the briefing already
  # counts what was sent.
  defp listed(ledger) do
    for {key, label} <- @listed,
        %{"included" => included, "eligible" => eligible} <- [ledger[key]],
        is_integer(included) and is_integer(eligible) and eligible > included,
        do: {label, "#{included} of #{eligible} sent"}
  end

  defp limits(%{"max_inputs" => inputs, "context_bytes" => bytes})
       when is_integer(inputs) and is_integer(bytes),
       do: "Up to #{inputs} messages · #{div(bytes, 1_024)} KiB of context"

  defp limits(_limits), do: nil

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(value, noun), do: "#{value} #{noun}s"

  defp count(value, noun) when is_integer(value), do: "#{value} #{noun}"
  defp count(_value, _noun), do: nil

  defp positive(value, format) when is_integer(value) and value > 0, do: format.(value)
  defp positive(_value, _format), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0

  defp join(parts) do
    case Enum.reject(parts, &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end
end
