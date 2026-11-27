defmodule Ryker.ControlPlane.AccountLimitsProjection do
  @moduledoc """
  Model account access and provider allowance are separate evidence. The Models
  page reads controller custody; a worker's local account alias cannot establish
  which central credential or quota principal its figures describe. Until the
  controller has matching allowance evidence, those figures remain unavailable.

  `entries/2` formats recorded provider windows with their check time; reports
  older than twenty minutes are stale rather than current.
  """
  alias Ryker.CoopFleet
  alias Ryker.Wording

  @stale_after_seconds 20 * 60

  @type window :: %{
          label: String.t(),
          detail: String.t() | nil,
          resets_at: DateTime.t() | nil,
          used_up: boolean()
        }
  @type entry :: %{
          state:
            :current
            | :stale
            | :unavailable
            | :access_unavailable
            | :not_signed_in
            | :sign_in_again,
          checked_at: DateTime.t() | nil,
          windows: [window()],
          plan: String.t() | nil,
          auth: String.t() | nil,
          resets: %{available: non_neg_integer() | nil, expires_at: [DateTime.t()]} | nil,
          used_up: window() | nil,
          credits: window() | nil
        }

  @doc "Controller readiness and independently attributed worker allowance reports."
  @spec page(DateTime.t()) :: %{String.t() => entry()}
  def page(now \\ DateTime.utc_now(:second)) do
    case CoopFleet.model_account_statuses() do
      {:ok, statuses} ->
        workers = worker_reports(now)

        Map.new(controller_entries(statuses), fn {name, entry} ->
          {name, Map.put(entry, :worker_reports, Enum.sort(Map.get(workers, name, [])))}
        end)

      _unavailable ->
        %{}
    end
  end

  defp worker_reports(now) do
    for report <- CoopFleet.account_usage_reports(),
        {name, limits} <- entries([report], now),
        reduce: %{} do
      acc ->
        item = {report.worker_id, limits}
        Map.update(acc, name, [item], &[item | &1])
    end
  end

  @doc "Controller access determines readiness; worker aliases do not prove central quota identity."
  def controller_entries(statuses) do
    Map.new(statuses, fn {name, status} ->
      state =
        case status.state do
          :missing -> :not_signed_in
          :configured -> :unavailable
          :unavailable -> :access_unavailable
          _repair -> :sign_in_again
        end

      {name,
       %{
         state: state,
         checked_at: nil,
         windows: [],
         plan: nil,
         auth: nil,
         resets: nil,
         used_up: nil,
         credits: nil
       }}
    end)
  end

  @doc """
  Each account's entry from the workers' reports, most recently seen worker
  first: where two workers hold the same account, the newer check wins.
  """
  @spec entries([map()], DateTime.t()) :: %{String.t() => entry()}
  def entries(reports, now) do
    reports
    |> Enum.flat_map(& &1.accounts)
    |> Enum.reduce(%{}, fn account, chosen ->
      Map.update(chosen, account["account"], account, &newer(&1, account))
    end)
    |> Map.new(fn {name, account} -> {name, entry(account, now)} end)
  end

  defp newer(kept, other) do
    if later?(time(other["checked_at"]), time(kept["checked_at"])), do: other, else: kept
  end

  defp later?(nil, _kept), do: false
  defp later?(_other, nil), do: true
  defp later?(other, kept), do: DateTime.compare(other, kept) == :gt

  defp entry(account, now) do
    checked_at = time(account["checked_at"])
    windows = Enum.map(account["limits"], &window/1)
    resets = resets(account["reset_credits"])

    %{
      state: state(account, checked_at, windows, resets, now),
      checked_at: checked_at,
      windows: windows,
      plan: account["plan"],
      auth: account["auth"],
      resets: resets,
      used_up: Enum.find(windows, & &1.used_up),
      credits: Enum.find(windows, &credits?/1)
    }
  end

  defp state(%{"sign_in" => "not_signed_in"}, _checked, _windows, _resets, _now),
    do: :not_signed_in

  defp state(%{"sign_in" => "sign_in_again"}, _checked, _windows, _resets, _now),
    do: :sign_in_again

  defp state(_account, nil, _windows, _resets, _now), do: :unavailable
  defp state(_account, _checked, [], nil, _now), do: :unavailable

  defp state(account, checked_at, _windows, _resets, now) do
    if account["error"] || DateTime.diff(now, checked_at) > @stale_after_seconds,
      do: :stale,
      else: :current
  end

  # A balance the account can still spend once a window is used up, such as
  # Codex's credits: VA1's account showed "Weekly limit used up" on every model
  # while 59,231.90 credits were left (2026-11-21).
  defp credits?(%{label: label, detail: detail, used_up: false}) when is_binary(detail),
    do: Regex.match?(~r/credits\z/i, label)

  defp credits?(_window), do: false

  # "5-hour limit · 18% left": a time window says it is a limit; credits and a
  # model's own window keep the provider's name.
  defp window(limit) do
    used = limit["used_percent"]
    used_up = limit["available"] == false or (is_number(used) and used >= 100)

    %{
      label: label(limit["name"]),
      detail: detail(limit, used, used_up),
      resets_at: time(limit["resets_at"]),
      used_up: used_up
    }
  end

  defp label(name) do
    if Regex.match?(~r/(?:\A|· )(?:\d+-hour|weekly|daily|monthly)\z/i, name),
      do: name <> " limit",
      else: name
  end

  defp detail(_limit, _used, true), do: "used up"
  defp detail(_limit, used, false) when is_number(used), do: "#{max(100 - round(used), 0)}% left"
  defp detail(%{"remaining" => "unlimited"}, nil, false), do: "unlimited"

  defp detail(%{"remaining" => remaining}, nil, false) when is_binary(remaining),
    do: amount(remaining) <> " left"

  defp detail(%{"note" => note}, nil, false), do: note

  # The provider's own amount in its own unit, read the way a person writes a
  # number: Codex sent its credit balance as "45229.7698855000" (2026-11-21).
  defp amount(remaining) do
    if Regex.match?(~r/\A\d+(\.\d+)?\z/, remaining) do
      rounded = remaining |> Decimal.new() |> Decimal.round(2) |> Decimal.to_string(:normal)
      [whole | fraction] = String.split(rounded, ".")
      whole = Wording.number(String.to_integer(whole))

      case fraction do
        [cents] when cents not in ["0", "00"] ->
          whole <> "." <> String.pad_trailing(cents, 2, "0")

        _whole ->
          whole
      end
    else
      remaining
    end
  end

  defp resets(nil), do: nil

  defp resets(%{"available" => available, "expires_at" => expiries}),
    do: %{available: available, expires_at: Enum.map(expiries, &time/1)}

  defp time(nil), do: nil

  defp time(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    DateTime.truncate(at, :second)
  end
end
