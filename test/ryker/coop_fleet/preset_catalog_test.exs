defmodule Ryker.CoopFleet.PresetCatalogTest do
  use ExUnit.Case, async: true
  alias Ryker.Config
  alias Ryker.CoopFleet.PresetCatalog

  @tag :tmp_dir
  test "only the approved recipe and its eligible accounts enter a new job", %{tmp_dir: root} do
    on_exit(fn -> File.rm_rf!(root) end)
    Config.put_override(:coop_job_presets_dir, root)

    %{"job" => job} =
      "testdata/protocol/coop-job-preset-v1.json" |> File.read!() |> Jason.decode!()

    document = Map.take(job, ["targets", "preset"])
    path = Path.join(root, "review.json")
    File.write!(path, Jason.encode!(document))
    accounts = ["codex@default", "claude@review"]
    assert PresetCatalog.names() == ["review"]

    assert PresetCatalog.resolve("subdir/review", accounts, true) ==
             {:error, {:coop_job_preset, "subdir/review", :unavailable}}

    assert {:ok, ^document} = PresetCatalog.resolve("review", accounts, true)

    assert PresetCatalog.resolve("review", ["codex@default"], true) ==
             {:error, {:coop_job_preset, "review", :account_unavailable}}

    updated = put_in(document, ["preset", "lead_prompt"], "Read the approved revision.")
    File.write!(path, Jason.encode!(updated))
    assert {:ok, ^updated} = PresetCatalog.resolve("review", accounts, true)
    File.rm!(path)

    assert PresetCatalog.resolve("review", accounts, true) ==
             {:error, {:coop_job_preset, "review", :unavailable}}

    File.write!(Path.join(root, "other.json"), Jason.encode!(document))
    File.ln_s!("other.json", path)

    assert PresetCatalog.resolve("review", accounts, true) ==
             {:error, {:coop_job_preset, "review", :unavailable}}

    assert PresetCatalog.resolve("other", accounts, true) ==
             {:error, {:coop_job_preset, "other", :invalid}}
  end
end
