defmodule Ryker.ControlPlane.ContextSelection do
  @moduledoc """
  What a Work turn's selection ledger adds to its briefing.

  The ledger is Ryker's own record of choosing what one turn sends, written
  beside the frozen submission and never inside it. Its facts sit beside the
  briefing rows they qualify: how many of the request's earlier messages a new
  session was not sent, and which limit left them out, and how many of each
  kind of saved context there were when some of it was not sent. The record
  itself stays stored beside the submission, not in the human briefing. A card
  of its own before the briefing said the same in a sentence, apart from its messages,
  and was dropped (Andrew, 2026-10-16).
  """
  alias Ryker.ControlPlane.Units

  @listed ~w(observations knowledge records related_outcomes guidance memory standing_assignments)

  @doc """
  The ledger's facts for the briefing, or nil when the turn recorded none:
  `left_out`, the earlier messages a new session was not sent; `listed`, each
  kind of saved context some of which was not sent, as `{included, eligible}`;
  `limits` in words. The original ledger remains on the turn.
  """
  @spec present(map() | nil) :: map() | nil
  def present(%{"inputs" => %{} = inputs} = ledger) do
    %{
      left_out: left_out(ledger["mode"], inputs, ledger["limits"]),
      listed: listed(ledger),
      limits: limits(ledger["limits"])
    }
  end

  def present(_ledger), do: nil

  # Only a new session leaves earlier messages out. A continued session
  # already holds them, so they are never counted as missing.
  defp left_out("full", inputs, limits) do
    window = integer(inputs["omitted_window"])
    fit = integer(inputs["omitted_fit"])

    if window + fit > 0,
      do: %{window: window, fit: fit, max_inputs: max_inputs(limits)}
  end

  defp left_out(_mode, _inputs, _limits), do: nil

  defp max_inputs(%{"max_inputs" => max}) when is_integer(max), do: max
  defp max_inputs(_limits), do: nil

  # Only kinds where something existed but was not sent; a count with nothing
  # left out said nothing ("1 of 1 message sent", Andrew, 2026-09-26).
  defp listed(ledger) do
    for key <- @listed,
        %{"included" => included, "eligible" => eligible} <- [ledger[key]],
        is_integer(included) and is_integer(eligible) and eligible > included,
        into: %{},
        do: {key, {included, eligible}}
  end

  defp limits(%{"max_inputs" => inputs, "context_bytes" => bytes})
       when is_integer(inputs) and is_integer(bytes),
       do: "Up to #{inputs} messages · #{Units.bytes(bytes)} of context"

  defp limits(_limits), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: 0
end
