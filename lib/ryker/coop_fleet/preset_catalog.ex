defmodule Ryker.CoopFleet.PresetCatalog do
  @moduledoc """
  The Coop recipes an owner built under Settings › Models › Presets, each
  saved under its name as `coop presets NAME --export-job` writes one. New
  jobs read the saved recipe; a pinned job already carries its contents.

  Until 2026-11-21 a recipe had to be a file in the controller's state volume,
  which an install on Nomad could not reach (Andrew: "how do I use presets in
  models selector?!"). Pasting the export came next, and the same day a form
  that picks each model the way the lists of models do (Andrew: "cant you
  build a nice ux here to build preset instead of copy-pasting yaml?").
  """
  alias Ryker.CoopFleet.JobPreset
  alias Ryker.Maps
  alias Ryker.Settings

  @limit 256 * 1024
  @modes ~w(consult delegate native)

  @doc "Whether `recipe` is a whole export of the preset `name`, as a writable job may run it."
  @spec recipe?(term(), term()) :: boolean()
  def recipe?(name, %{"preset" => %{"name" => name}} = recipe) do
    JobPreset.name?(name) and Maps.exact_keys?(recipe, ~w(preset targets)) and
      byte_size(Jason.encode!(recipe)) <= @limit and
      JobPreset.valid?(Map.put(recipe, "repository_read_only", false))
  end

  def recipe?(_name, _recipe), do: false

  @doc """
  The recipe for a preset as its form describes it: `name`, the `lead` models
  in the order Coop tries them, the lead's instructions (`lead_prompt`) and
  its `roles`, each `name`, `mode`, `targets`, `when` and `prompt`. Every
  model has each part chosen and runs on one of `accounts`. A refusal names
  each part to change by the field it is in, so the form can say it there.
  """
  @spec build(map(), [String.t()]) :: {:ok, map()} | {:error, [{atom(), atom()}]}
  def build(preset, accounts) when is_map(preset) do
    name = Map.get(preset, :name)
    lead = Map.get(preset, :lead) || []
    lead_prompt = Map.get(preset, :lead_prompt) || ""
    roles = Map.get(preset, :roles) || []

    errors =
      Enum.reject(
        [
          name: name_reason(name),
          lead: models_reason(lead, accounts),
          lead_prompt: if(JobPreset.prompt?(lead_prompt), do: nil, else: :length),
          roles: roles_reason(roles, lead, accounts)
        ],
        fn {_field, reason} -> is_nil(reason) end
      )

    recipe = %{
      "targets" => lead,
      "preset" => %{
        "version" => 1,
        "name" => name,
        "lead_prompt" => lead_prompt,
        "roles" => roles
      }
    }

    cond do
      errors != [] -> {:error, errors}
      recipe?(name, recipe) -> {:ok, recipe}
      # Each part fits, so what is left is the whole: sixteen long roles.
      true -> {:error, [roles: :size]}
    end
  end

  defp name_reason(name) when name in [nil, ""], do: :required
  defp name_reason(name), do: if(JobPreset.name?(name), do: nil, else: :format)

  defp models_reason(targets, accounts) when is_list(targets) do
    cond do
      length(targets) not in 1..Settings.Work.most_models() -> :length
      not Enum.all?(targets, &Settings.Work.target?/1) -> :format
      Enum.uniq(targets) != targets -> :duplicate
      Enum.any?(targets, &(Settings.Work.account(&1) not in accounts)) -> :unknown_account
      true -> nil
    end
  end

  defp models_reason(_targets, _accounts), do: :format

  # Each role on its own first, then what the roles share with each other and
  # with the lead, once the lead's models are whole.
  defp roles_reason(roles, _lead, _accounts) when not is_list(roles), do: :length

  defp roles_reason(roles, lead, accounts) do
    names = Enum.map(roles, & &1["name"])

    cond do
      length(roles) > JobPreset.most_roles() -> :length
      reason = Enum.find_value(roles, &role_reason(&1, accounts)) -> reason
      Enum.uniq(names) != names -> :role_names
      models_reason(lead, accounts) -> nil
      not JobPreset.native_on_lead_account?(lead, roles) -> :native
      not JobPreset.one_account_per_provider?(lead, roles) -> :accounts
      true -> nil
    end
  end

  defp role_reason(role, accounts) do
    cond do
      not JobPreset.role_name?(role["name"]) -> :role_name
      role["mode"] not in @modes -> :mode
      reason = models_reason(role["targets"], accounts) -> role_models(reason)
      role["mode"] == "native" and length(role["targets"]) != 1 -> :native
      not JobPreset.hints?(role["when"]) -> :hints
      not JobPreset.prompt?(role["prompt"]) -> :role_prompt
      true -> nil
    end
  end

  # A role's list says what is wrong with it as the lead's does, except that
  # an unfinished or empty one is the role's models, not the lead's.
  defp role_models(reason) when reason in [:length, :format], do: :role_models
  defp role_models(reason), do: reason

  @doc "The saved presets whose every account is listed, as Settings › Models offers them."
  @spec choices(Settings.Work.t()) :: [map()]
  def choices(%Settings.Work{presets: presets, model_accounts: accounts}) do
    for {name, _recipe} <- Enum.sort(presets || %{}),
        {:ok, recipe} <- [resolve(name, presets, accounts, false)] do
      roles = Enum.map(recipe["preset"]["roles"], &Map.take(&1, ~w(name mode targets)))

      %{
        name: name,
        targets: recipe["targets"],
        roles: roles,
        read_only: Enum.all?(roles, &(&1["mode"] != "delegate"))
      }
    end
  end

  @doc """
  The saved recipe `name` for a job: refused when it is not saved, cannot run
  as the job does (a delegate role in a read-only job), or names an account
  that is not listed.
  """
  @spec resolve(String.t(), map() | nil, [String.t()], boolean()) ::
          {:ok, map()} | {:error, {:coop_job_preset, String.t(), atom()}}
  def resolve(name, presets, accounts, read_only) do
    recipe = Map.get(presets || %{}, name)

    cond do
      not recipe?(name, recipe) ->
        {:error, {:coop_job_preset, name, :unavailable}}

      not JobPreset.valid?(Map.put(recipe, "repository_read_only", read_only)) ->
        {:error, {:coop_job_preset, name, :invalid}}

      not Enum.all?(requested(recipe), &(Settings.Work.account(&1) in accounts)) ->
        {:error, {:coop_job_preset, name, :account_unavailable}}

      true ->
        {:ok, recipe}
    end
  end

  defp requested(recipe),
    do: recipe["targets"] ++ Enum.flat_map(recipe["preset"]["roles"], & &1["targets"])
end
