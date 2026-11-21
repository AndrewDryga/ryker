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

  # Andrew, 2026-11-21: "cant you build a nice ux here to build preset instead of copy-pasting
  # yaml?" The Models page builds the recipe from rows of model choices, so a refusal has to name
  # the part to change: one "invalid preset" would leave a person guessing which of a dozen
  # choices Coop would refuse.
  test "a built preset is the recipe Coop exports, or the part of it to change" do
    accounts = ["codex@default", "codex@work", "claude@review"]

    critic = %{
      "name" => "critic",
      "mode" => "consult",
      "targets" => ["claude:claude-opus-5-5/high@review"],
      "when" => ["plan review"],
      "prompt" => ""
    }

    preset = %{
      name: "review",
      lead: ["codex:gpt-6.2-sol/medium@default"],
      lead_prompt: "",
      roles: [critic]
    }

    assert {:ok, recipe} = PresetCatalog.build(preset, accounts)

    assert recipe == %{
             "targets" => preset.lead,
             "preset" => %{
               "version" => 1,
               "name" => "review",
               "lead_prompt" => "",
               "roles" => [critic]
             }
           }

    assert PresetCatalog.recipe?("review", recipe)
    with_role = fn changes -> %{preset | roles: [Map.merge(critic, changes)]} end

    refusals = [
      {%{preset | name: nil}, [name: :required]},
      {%{preset | name: "Review"}, [name: :format]},
      {%{preset | name: "", lead: []}, [name: :required, lead: :length]},
      {%{preset | lead: ["codex:gpt-6.2-sol/@default"]}, [lead: :format]},
      {%{preset | lead: List.duplicate("codex:gpt-6.2-sol/medium@default", 2)},
       [lead: :duplicate]},
      {%{preset | lead: ["codex:gpt-6.2-sol/medium@spare"]}, [lead: :unknown_account]},
      {%{preset | lead_prompt: String.duplicate("a", 32 * 1024 + 1)}, [lead_prompt: :length]},
      {with_role.(%{"name" => "Critic"}), [roles: :role_name]},
      {%{preset | roles: [critic, critic]}, [roles: :role_names]},
      {with_role.(%{"mode" => "boss"}), [roles: :mode]},
      {with_role.(%{"targets" => ["claude:claude-opus-5-5/@review"]}), [roles: :role_models]},
      {with_role.(%{"targets" => []}), [roles: :role_models]},
      {with_role.(%{"targets" => ["claude:claude-opus-5-5/high@spare"]}),
       [roles: :unknown_account]},
      {with_role.(%{"when" => [" "]}), [roles: :hints]},
      # A native role runs in the lead's own session, so on the lead's account.
      {with_role.(%{"mode" => "native"}), [roles: :native]},
      # A box signs in once per provider: a Codex role beside a Codex lead shares its account.
      {with_role.(%{"targets" => ["codex:gpt-6.2-sol/high@work"]}), [roles: :accounts]}
    ]

    for {refused, errors} <- refusals do
      assert PresetCatalog.build(refused, accounts) == {:error, errors}, inspect(refused)
    end
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
