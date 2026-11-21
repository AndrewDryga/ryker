defmodule Ryker.CoopFleet.JobPreset do
  @moduledoc "The versioned lead and role instructions frozen into a worker job."
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.Settings

  @name ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @role_name ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @most_roles 16
  @target ~r/\A(?:codex|claude)(?::[a-zA-Z0-9][a-zA-Z0-9._-]*)?(?:\/(?:low|medium|high|xhigh))?(?:\+fast)?@[a-z0-9][a-z0-9_-]{0,63}\z/

  def name?(name), do: Reference.matches?(name, @name)

  def role_name?(name), do: Reference.matches?(name, @role_name)

  def valid?(%{"preset" => preset, "targets" => leads, "repository_read_only" => read_only}) do
    Maps.exact_keys?(preset, ~w(version name lead_prompt roles)) and
      preset["version"] === 1 and name?(preset["name"]) and
      prompt?(preset["lead_prompt"]) and targets?(leads) and
      roles?(preset["roles"], leads, read_only)
  end

  def valid?(job), do: not Map.has_key?(job, "preset")

  defp roles?(roles, leads, read_only) when is_list(roles) and length(roles) <= @most_roles do
    Enum.all?(roles, &role?(&1, read_only)) and Enum.uniq_by(roles, & &1["name"]) == roles and
      one_account_per_provider?(leads, roles) and native_on_lead_account?(leads, roles)
  end

  defp roles?(_roles, _leads, _read_only), do: false

  defp role?(role, read_only) do
    Maps.exact_keys?(role, ~w(name mode targets when prompt)) and
      role_name?(role["name"]) and targets?(role["targets"]) and
      hints?(role["when"]) and prompt?(role["prompt"]) and
      mode?(role["mode"], role["targets"], read_only)
  end

  defp mode?("consult", _targets, _read_only), do: true
  defp mode?("delegate", _targets, read_only), do: not read_only
  defp mode?("native", [_one], _read_only), do: true
  defp mode?(_mode, _targets, _read_only), do: false

  @doc """
  Whether one sign-in per provider serves each lead model and every role
  beside it: a box mounts one login per provider.
  """
  @spec one_account_per_provider?([String.t()], [map()]) :: boolean()
  def one_account_per_provider?(leads, roles) do
    Enum.all?(leads, fn lead ->
      accounts =
        [lead | Enum.flat_map(roles, & &1["targets"])]
        |> Enum.map(&Settings.Work.account/1)
        |> Enum.uniq()

      providers = Enum.map(accounts, &hd(String.split(&1, "@", parts: 2)))
      Enum.uniq(providers) == providers
    end)
  end

  @doc """
  Whether each native role runs on the account of every lead model: it runs
  inside the lead's session, including when a retry moves to another lead.
  """
  @spec native_on_lead_account?([String.t()], [map()]) :: boolean()
  def native_on_lead_account?(leads, roles) do
    for role <- roles, role["mode"] == "native", lead <- leads, reduce: true do
      matched ->
        matched and Settings.Work.account(hd(role["targets"])) == Settings.Work.account(lead)
    end
  end

  defp targets?(values) when is_list(values) and length(values) in 1..4 do
    Enum.all?(
      values,
      &(is_binary(&1) and byte_size(&1) <= 256 and Reference.matches?(&1, @target))
    )
  end

  defp targets?(_values), do: false

  @doc "Whether `values` are a role's `when` hints: at most sixteen short phrases, none blank."
  @spec hints?(term()) :: boolean()
  def hints?(values) when is_list(values) and length(values) <= 16,
    do: Enum.all?(values, &(is_binary(&1) and byte_size(&1) <= 512 and String.trim(&1) != ""))

  def hints?(_values), do: false

  @doc "Whether `text` fits as the lead's or a role's instructions: UTF-8, at most 32 KiB."
  @spec prompt?(term()) :: boolean()
  def prompt?(text), do: is_binary(text) and byte_size(text) <= 32 * 1024 and String.valid?(text)

  @doc "The most roles one preset holds."
  @spec most_roles() :: pos_integer()
  def most_roles, do: @most_roles
end
