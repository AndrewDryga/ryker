defmodule Ryker.CoopFleet.PresetCatalog do
  @moduledoc """
  The Coop recipes an owner saved under Settings › Models › Presets, each the
  output of `coop presets NAME --export-job` under its name. New jobs read the
  saved recipe; a pinned job already carries its contents.

  Until 2026-11-21 a recipe had to be a file in the controller's state volume,
  which an install on Nomad could not reach (Andrew: "how do I use presets in
  models selector?!").
  """
  alias Ryker.CoopFleet.JobPreset
  alias Ryker.Maps
  alias Ryker.Settings

  @limit 256 * 1024

  @doc "Whether `recipe` is a whole export of the preset `name`, as a writable job may run it."
  @spec recipe?(term(), term()) :: boolean()
  def recipe?(name, %{"preset" => %{"name" => name}} = recipe) do
    JobPreset.name?(name) and Maps.exact_keys?(recipe, ~w(preset targets)) and
      byte_size(Jason.encode!(recipe)) <= @limit and
      JobPreset.valid?(Map.put(recipe, "repository_read_only", false))
  end

  def recipe?(_name, _recipe), do: false

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
