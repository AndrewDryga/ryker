defmodule Ryker.Delivery.OfferWords do
  @moduledoc """
  The words an offer uses for its facts, shared by the Chat card and the Slack
  card so the same offer says the same thing in both places: who a saved
  memory or preference applies to, who sees it, how long it lasts, what an
  automation listens to, and how often a schedule runs.

  Each returns nil when there is nothing to say, so a card leaves the fact
  out instead of showing a blank or an internal value.
  """
  alias Ryker.Schedules

  @doc "Who a saved memory, preference or guidance applies to."
  @spec applies_to(String.t() | nil, String.t() | nil) :: String.t() | nil
  def applies_to("operator", _repository), do: "Just you"
  def applies_to("conversation", _repository), do: "This conversation"

  def applies_to("repository", repository) when is_binary(repository),
    do: "Work in " <> repository

  def applies_to("workspace", _repository), do: "Everyone in this workspace"
  def applies_to(_scope, _repository), do: nil

  @doc "Who may see it, only where that differs from who it applies to."
  @spec shown_to(String.t() | nil, String.t() | nil) :: String.t() | nil
  def shown_to(scope, visibility)
      when {scope, visibility} in [
             {"operator", "private"},
             {"conversation", "conversation"},
             {"workspace", "workspace"}
           ],
      do: nil

  def shown_to(_scope, "private"), do: "Only you"
  def shown_to(_scope, "conversation"), do: "This conversation only"
  def shown_to(_scope, "workspace"), do: "Everyone in this workspace"
  def shown_to(_scope, _visibility), do: nil

  @doc ~s(A stored duration such as "90d" as "90 days".)
  @spec duration(String.t() | nil) :: String.t() | nil
  def duration(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)([smhdw])$/, value) do
      [_, count, unit] -> count <> " " <> unit(unit, count)
      _other -> humanize(value)
    end
  end

  def duration(nil), do: nil
  def duration(value), do: to_string(value)

  defp unit("s", "1"), do: "second"
  defp unit("s", _count), do: "seconds"
  defp unit("m", "1"), do: "minute"
  defp unit("m", _count), do: "minutes"
  defp unit("h", "1"), do: "hour"
  defp unit("h", _count), do: "hours"
  defp unit("d", "1"), do: "day"
  defp unit("d", _count), do: "days"
  defp unit("w", "1"), do: "week"
  defp unit("w", _count), do: "weeks"

  @doc "What a standing assignment listens to."
  @spec listens_to(map()) :: String.t() | nil
  def listens_to(%{"source_kind" => "github"}), do: "GitHub events"
  def listens_to(%{"source_kind" => "slack"}), do: "Slack messages here"
  def listens_to(%{"source_kind" => "webhook"}), do: "Webhook events"
  def listens_to(%{"source_kind" => kind}) when is_binary(kind), do: humanize(kind) <> " events"
  def listens_to(_payload), do: nil

  @doc ~s(Which events an automation takes, from its filter: "Only when action is submitted".)
  @spec only_when(map() | nil) :: String.t() | nil
  def only_when(filter) when is_map(filter) and map_size(filter) > 0 do
    conditions =
      filter
      |> Enum.sort()
      |> Enum.map_join(" and ", fn {key, value} ->
        key |> humanize() |> String.downcase() |> Kernel.<>(" is " <> value(value))
      end)

    "Only when " <> conditions
  end

  def only_when(_filter), do: nil

  defp value(value) when is_binary(value), do: value
  defp value(value) when is_list(value), do: Enum.map_join(value, " or ", &value/1)
  defp value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp value(value), do: Jason.encode!(value)

  @doc "An exact moment, as every card writes one: \"12 Oct 2026, 09:00 UTC\"."
  @spec stamp(String.t() | nil) :: String.t() | nil
  def stamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%-d %b %Y, %H:%M UTC")
      _invalid -> nil
    end
  end

  def stamp(_value), do: nil

  @doc """
  How often a time automation runs, from its trigger, in the words the
  schedule itself uses.
  """
  @spec cadence(map() | nil) :: String.t() | nil
  def cadence(trigger) when is_map(trigger) do
    case Schedules.ScheduleRecurrence.from_trigger(trigger) do
      {:ok, recurrence} -> Schedules.ScheduleCadence.describe(recurrence, trigger["timezone"])
      {:error, _reason} -> nil
    end
  end

  def cadence(_trigger), do: nil

  @doc ~s(A stored name as words: "response_detail" becomes "Response detail".)
  @spec humanize(term()) :: String.t()
  def humanize(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  def humanize(value), do: to_string(value)
end
