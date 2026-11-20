defmodule Ryker.CoopFleet.JobPreset do
  @moduledoc "The versioned lead and role instructions frozen into a worker job."
  alias Ryker.Maps
  alias Ryker.Settings

  @name ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @role_name ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @target ~r/\A(?:codex|claude)(?::[a-zA-Z0-9][a-zA-Z0-9._-]*)?(?:\/(?:low|medium|high|xhigh))?@[a-z0-9][a-z0-9_-]{0,63}\z/

  def name?(name), do: matches?(name, @name)

  def valid?(%{"preset" => preset, "targets" => leads, "repository_read_only" => read_only}) do
    Maps.exact_keys?(preset, ~w(version name lead_prompt roles)) and
      preset["version"] === 1 and name?(preset["name"]) and
      prompt?(preset["lead_prompt"]) and targets?(leads) and
      roles?(preset["roles"], leads, read_only)
  end

  def valid?(job), do: not Map.has_key?(job, "preset")

  defp roles?(roles, leads, read_only) when is_list(roles) and length(roles) <= 16 do
    Enum.all?(roles, &role?(&1, read_only)) and Enum.uniq_by(roles, & &1["name"]) == roles and
      Enum.all?(leads, &accounts_match?(&1, roles))
  end

  defp roles?(_roles, _leads, _read_only), do: false

  defp role?(role, read_only) do
    Maps.exact_keys?(role, ~w(name mode targets when prompt)) and
      matches?(role["name"], @role_name) and targets?(role["targets"]) and
      hints?(role["when"]) and prompt?(role["prompt"]) and
      mode?(role["mode"], role["targets"], read_only)
  end

  defp mode?("consult", _targets, _read_only), do: true
  defp mode?("delegate", _targets, read_only), do: not read_only
  defp mode?("native", [_one], _read_only), do: true
  defp mode?(_mode, _targets, _read_only), do: false

  # A box mounts one login per provider. Native roles run inside the current
  # lead's session, including when a retry moves to a different lead target.
  defp accounts_match?(lead, roles) do
    lead_account = Settings.Work.account(lead)
    targets = [lead | Enum.flat_map(roles, & &1["targets"])]
    accounts = targets |> Enum.map(&Settings.Work.account/1) |> Enum.uniq()
    providers = Enum.map(accounts, &hd(String.split(&1, "@", parts: 2)))

    Enum.uniq(providers) == providers and
      Enum.all?(roles, fn role ->
        role["mode"] != "native" or Settings.Work.account(hd(role["targets"])) == lead_account
      end)
  end

  defp targets?(values) when is_list(values) and length(values) in 1..4,
    do: Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 256 and matches?(&1, @target)))

  defp targets?(_values), do: false

  defp hints?(values) when is_list(values) and length(values) <= 16,
    do: Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 512 and String.trim(&1) != ""))

  defp hints?(_values), do: false
  defp prompt?(text), do: is_binary(text) and byte_size(text) <= 32 * 1024 and String.valid?(text)
  defp matches?(text, regex), do: is_binary(text) and Regex.match?(regex, text)
end
