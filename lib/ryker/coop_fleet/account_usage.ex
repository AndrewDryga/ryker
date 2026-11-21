defmodule Ryker.CoopFleet.AccountUsage do
  @moduledoc """
  What a worker's providers last reported about the allowance left on each
  account it holds: the hello's `account_usage` (Coop's
  `workerproto.AccountUsage`, version 1). Each account lists the windows
  `coop usage` shows, with the share of each used and when it resets, and
  when its provider last answered. The worker reads its providers with its own
  sign-ins, so no credential reaches Ryker.

  It is display data. A report this controller cannot read is dropped, never
  a reason to refuse the worker's poll: a refused poll stops every command the
  worker carries. The rules match Coop's own, so a report Coop publishes is one
  Ryker keeps.
  """
  alias Ryker.UTCDateTime

  @version 1
  @most_accounts 32
  @most_limits 32
  @most_expiries 32
  @most_text 256
  @most_bytes 65_536
  @sign_ins ~w(signed_in not_signed_in sign_in_again)
  @errors ~w(sign_in_refused unavailable)
  @account_fields ~w(account sign_in checked_at attempted_at error plan auth note limits reset_credits)
  @limit_fields ~w(name used_percent remaining resets_at available note)

  @doc "The report as it may be stored, or nil when it is absent or cannot be read."
  @spec normalize(term()) :: map() | nil
  def normalize(%{"version" => @version, "accounts" => accounts} = usage)
      when map_size(usage) == 2 and is_list(accounts) and length(accounts) <= @most_accounts do
    with {:ok, accounts} <- all(accounts, &account/1),
         names = Enum.map(accounts, & &1["account"]),
         true <- unique?(names),
         report = %{"version" => @version, "accounts" => accounts},
         true <- byte_size(Jason.encode!(report)) <= @most_bytes do
      report
    else
      _unreadable -> nil
    end
  end

  def normalize(_usage), do: nil

  defp account(%{} = account) do
    with true <- Map.keys(account) |> Enum.sort() == Enum.sort(@account_fields),
         true <- account?(account["account"]),
         true <- account["sign_in"] in @sign_ins,
         true <- is_nil(account["error"]) or account["error"] in @errors,
         {:ok, checked} <- optional_time(account["checked_at"]),
         {:ok, attempted} <- optional_time(account["attempted_at"]),
         true <- coherent_reads?(checked, attempted, account["error"]),
         true <- Enum.all?(~w(plan auth note), &text?(account[&1])),
         limits when is_list(limits) and length(limits) <= @most_limits <- account["limits"],
         {:ok, limits} <- all(limits, &limit/1),
         {:ok, credits} <- reset_credits(account["reset_credits"]),
         true <- checked != nil or figureless?(account) do
      {:ok,
       %{
         account
         | "checked_at" => UTCDateTime.iso8601(checked),
           "attempted_at" => UTCDateTime.iso8601(attempted),
           "limits" => limits,
           "reset_credits" => credits
       }}
    else
      _invalid -> :error
    end
  end

  defp account(_account), do: :error

  # A read that succeeded is the answer it checked; one that failed keeps an
  # older answer, or none; nothing is checked without an attempt.
  defp coherent_reads?(nil, nil, nil), do: true
  defp coherent_reads?(_checked, nil, _error), do: false
  defp coherent_reads?(checked, attempted, nil), do: checked != nil and checked == attempted
  defp coherent_reads?(nil, _attempted, _error), do: true

  defp coherent_reads?(checked, attempted, _error),
    do: DateTime.compare(checked, attempted) != :gt

  defp figureless?(account) do
    account["limits"] == [] and is_nil(account["reset_credits"]) and
      Enum.all?(~w(plan auth note), &is_nil(account[&1]))
  end

  defp limit(%{} = limit) do
    with true <- Map.keys(limit) |> Enum.sort() == Enum.sort(@limit_fields),
         true <- text?(limit["name"]) and limit["name"] not in [nil, ""],
         true <- used?(limit["used_percent"]),
         true <- text?(limit["remaining"]) and text?(limit["note"]),
         true <- is_nil(limit["available"]) or is_boolean(limit["available"]),
         {:ok, resets_at} <- optional_time(limit["resets_at"]) do
      {:ok, %{limit | "resets_at" => UTCDateTime.iso8601(resets_at)}}
    else
      _invalid -> :error
    end
  end

  defp limit(_limit), do: :error

  defp reset_credits(nil), do: {:ok, nil}

  defp reset_credits(%{"available" => available, "expires_at" => expiries} = credits)
       when map_size(credits) == 2 and is_list(expiries) and length(expiries) <= @most_expiries do
    with true <- is_nil(available) or (is_integer(available) and available >= 0),
         {:ok, expiries} <- all(expiries, &time/1) do
      {:ok,
       %{"available" => available, "expires_at" => Enum.map(expiries, &DateTime.to_iso8601/1)}}
    else
      _invalid -> :error
    end
  end

  defp reset_credits(_credits), do: :error

  defp used?(nil), do: true
  defp used?(used) when is_number(used), do: used >= 0 and used <= 1_000
  defp used?(_used), do: false

  # provider@name with Coop's account rule: one path-safe segment, never ".",
  # ".." or a leading "-".
  defp account?(ref) when is_binary(ref) do
    with [provider, name] <- String.split(ref, "@", parts: 2),
         true <- Regex.match?(~r/\A[a-z][a-z0-9-]{0,31}\z/, provider),
         true <- byte_size(name) in 1..128 and text?(name) do
      not String.contains?(name, [":", "@", "/", "\\"]) and name not in [".", ".."] and
        not String.starts_with?(name, "-")
    else
      _invalid -> false
    end
  end

  defp account?(_ref), do: false

  defp text?(nil), do: true

  defp text?(text) when is_binary(text),
    do: byte_size(text) <= @most_text and String.valid?(text) and not control?(text)

  defp text?(_text), do: false

  defp control?(text), do: String.match?(text, ~r/[\x00-\x1f\x7f]/)

  defp optional_time(nil), do: {:ok, nil}
  defp optional_time(value), do: time(value)

  defp time(value) when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, at} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp time(_value), do: :error

  defp all(values, prepare) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, prepared} ->
      case prepare.(value) do
        {:ok, value} -> {:cont, {:ok, [value | prepared]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      :error -> :error
    end
  end

  defp unique?(values), do: length(Enum.uniq(values)) == length(values)
end
