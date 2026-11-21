defmodule Ryker.CoopFleet.PresetCatalogTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.PresetCatalog
  alias Ryker.Settings.Work

  setup do
    %{"job" => job} =
      "testdata/protocol/coop-job-preset-v1.json" |> File.read!() |> Jason.decode!()

    %{recipe: Map.take(job, ["targets", "preset"])}
  end

  test "only a saved recipe and its listed accounts enter a new job", %{recipe: recipe} do
    presets = %{"review" => recipe}
    accounts = ["codex@default", "claude@review"]

    assert PresetCatalog.resolve("review", presets, accounts, true) == {:ok, recipe}

    assert PresetCatalog.resolve("review", presets, ["codex@default"], true) ==
             {:error, {:coop_job_preset, "review", :account_unavailable}}

    assert PresetCatalog.resolve("other", presets, accounts, true) ==
             {:error, {:coop_job_preset, "other", :unavailable}}

    # A recipe saved under another name than its own is not that preset.
    assert PresetCatalog.resolve("other", %{"other" => recipe}, accounts, true) ==
             {:error, {:coop_job_preset, "other", :unavailable}}

    # A delegate may change files, so it never runs in a read-only review.
    writer =
      update_in(recipe, ["preset", "roles"], fn [role] -> [%{role | "mode" => "delegate"}] end)

    assert PresetCatalog.resolve("review", %{"review" => writer}, accounts, true) ==
             {:error, {:coop_job_preset, "review", :invalid}}

    assert {:ok, ^writer} =
             PresetCatalog.resolve("review", %{"review" => writer}, accounts, false)
  end

  test "a recipe is the whole export under its own name", %{recipe: recipe} do
    assert PresetCatalog.recipe?("review", recipe)
    refute PresetCatalog.recipe?("other", recipe)
    refute PresetCatalog.recipe?("review", Map.put(recipe, "extra", true))
    refute PresetCatalog.recipe?("review", Map.delete(recipe, "targets"))
    refute PresetCatalog.recipe?("review", nil)
  end

  test "the Models page offers each saved preset whose accounts are listed", %{recipe: recipe} do
    work = %Work{presets: %{"review" => recipe}, model_accounts: ["codex@default"]}
    assert PresetCatalog.choices(work) == []

    [choice] = PresetCatalog.choices(%{work | model_accounts: ["codex@default", "claude@review"]})
    assert choice.name == "review"
    assert choice.read_only
    assert choice.targets == recipe["targets"]
  end
end
