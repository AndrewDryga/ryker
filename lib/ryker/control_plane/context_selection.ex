defmodule Ryker.ControlPlane.ContextSelection do
  @moduledoc """
  What Ryker chose to send one Work turn, and what it left out, in plain words.

  The selection ledger is Ryker's own record of preparing the turn, not part
  of the prompt, so it is a card of its own before the Work briefing. The
  briefing shows exactly what was sent; this card says in a sentence which of
  the request's messages the model was given and why, then names the limits
  only when they cut something. A count with nothing left out ("1 of 1
  message sent") said nothing, so the card carries no counter.
  """
  alias Ryker.ControlPlane.Units

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
    listed = listed(ledger)
    cut? = left_out(ledger["mode"], inputs) > 0 or listed != []

    %{
      summary: nil,
      text: sentence(ledger["mode"], inputs, context, ledger["limits"]),
      facts:
        Enum.reject(
          listed ++ [{"Limits", if(cut?, do: limits(ledger["limits"]))}],
          &is_nil(elem(&1, 1))
        ),
      record: Jason.encode!(ledger, pretty: true),
      record_label: "Selection record"
    }
  end

  def present(_ledger, _context), do: nil

  # A continuation sends only what is new: the session already holds the rest.
  defp sentence("continuation", inputs, _context, _limits) do
    new = integer(inputs["current"])

    case integer(inputs["earlier_not_resent"]) do
      0 ->
        "The model was given only #{new_messages(new)}. This run continues the same session."

      earlier ->
        "The model was given only #{new_messages(new)}. This run continues the session, " <>
          "which already has the #{plural(earlier, "earlier message")} of this request."
    end
  end

  # A new session starts with nothing, so the request's earlier messages go
  # with the new ones, the most recent first to stay when something must go.
  defp sentence(_full, inputs, context, limits) do
    new = integer(inputs["current"])
    earlier = earlier_sent(inputs, context)
    left_out = left_out("full", inputs)

    given =
      cond do
        earlier > 0 and left_out > 0 ->
          "The model was given #{new_messages(new)} and the " <>
            most_recent(earlier) <> " of this request, " <> new_session()

        earlier > 0 ->
          "The model was given #{new_messages(new)} and the " <>
            "#{plural(earlier, "earlier message")} of this request, " <> new_session()

        left_out > 0 ->
          "The model was given #{new_messages(new)} only."

        true ->
          "The model was given #{new_messages(new)} only. " <> first(new)
      end

    [given, left_out_sentence(inputs, left_out, limits)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp new_session, do: "because this run started a new session, which had not seen them."

  defp first(1), do: "It is the first message of this request."
  defp first(_new), do: "They are the first messages of this request."

  defp new_messages(1), do: "this message"
  defp new_messages(count), do: "the #{count} new messages"

  defp most_recent(1), do: "1 most recent earlier message"
  defp most_recent(count), do: "#{count} most recent earlier messages"

  defp left_out_sentence(_inputs, 0, _limits), do: nil

  defp left_out_sentence(inputs, left_out, limits) do
    reasons =
      [
        positive(inputs["omitted_window"], &"#{&1} #{window(limits)}"),
        positive(inputs["omitted_fit"], &"#{&1} to fit the size limit")
      ]
      |> Enum.reject(&is_nil/1)

    "#{plural(left_out, "earlier message")} #{were(left_out)} left out: " <>
      Enum.join(reasons, " and ") <> "."
  end

  defp window(%{"max_inputs" => max}) when is_integer(max), do: "beyond the #{max} most recent"
  defp window(_limits), do: "outside the history window"

  defp left_out("full", inputs),
    do: integer(inputs["omitted_window"]) + integer(inputs["omitted_fit"])

  defp left_out(_mode, _inputs), do: 0

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
       do: "Up to #{inputs} messages · #{Units.bytes(bytes)} of context"

  defp limits(_limits), do: nil

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(value, noun), do: "#{value} #{noun}s"

  defp were(1), do: "was"
  defp were(_count), do: "were"

  defp positive(value, format) when is_integer(value) and value > 0, do: format.(value)
  defp positive(_value, _format), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0
end
