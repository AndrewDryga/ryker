defmodule Ryker.Evals.WorldSourceTest do
  use ExUnit.Case, async: true

  alias Ryker.Evals.{WorldCase, WorldSource}

  @at ~U[2026-08-21 02:21:46Z]

  # Coop finds a staged source by this key and nothing else. The value was printed by Go's
  # json.Marshal over copies of workerproto.JobSource and session.SourceBinding (2026-09-30), so
  # a drift in field order or shape fails here rather than as "job source is not staged".
  test "the staging key is the one Coop computes for the same source" do
    source =
      WorldSource.source(
        "blitz-rivals-scraper",
        String.duplicate("1", 40),
        String.duplicate("2", 40),
        ~U[2026-08-21 20:48:00Z]
      )

    assert WorldSource.go_json(source) ==
             ~s({"repository_ref":"blitz-rivals-scraper","github_repository":"ryker-eval/blitz-rivals-scraper","github_repository_id":1,"binding":{"version":1,"kind":"default","requested":{"kind":"default"},"remote_identity":"origin","default_ref":"refs/heads/main","default_commit":"1111111111111111111111111111111111111111","selected_ref":"refs/heads/main","selected_commit":"1111111111111111111111111111111111111111","base_commit":"1111111111111111111111111111111111111111","admitted_tree":"2222222222222222222222222222222222222222","resolved_at":"2026-08-21T20:48:00Z"},"submodules":[]})

    assert WorldSource.staging_key(source) ==
             "c95fd3ca6a1043ba8695f14155a04aa2a8b29383b074bf8059c6df209a871e93"
  end

  test "the captured Rivals checkout is staged once, at its key, with the exact commit" do
    root =
      Path.join(System.tmp_dir!(), "ryker-world-source-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, scenario} = WorldCase.fetch("rivals-engineering-task-offer")
    {:ok, [capture]} = WorldCase.fixture_context(scenario)

    assert {:ok, source} = WorldSource.stage(capture, root, @at)
    assert {:ok, ^source} = WorldSource.stage(capture, root, @at)

    directory = Path.join([root, "job-sources", WorldSource.staging_key(source)])
    assert File.read!(Path.join(directory, "source.json")) == WorldSource.go_json(source)
    assert File.stat!(Path.join(directory, "source.json")).mode |> Bitwise.band(0o077) == 0

    repository = Path.join(directory, "repository")
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD", "HEAD^{tree}"], cd: repository)

    assert String.split(head) == [
             source["binding"]["selected_commit"],
             source["binding"]["admitted_tree"]
           ]

    for file <- capture["files"],
        do: assert(File.read!(Path.join(repository, file["path"])) == file["data"])

    assert [_one] = root |> Path.join("job-sources") |> File.ls!()
  end

  # `--repeat 3` runs the same scenario in parallel shards, each staging it before its run.
  test "shards staging the same checkout at once all get it, staged once" do
    root =
      Path.join(System.tmp_dir!(), "ryker-world-source-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, scenario} = WorldCase.fetch("rivals-engineering-task-offer")
    {:ok, [capture]} = WorldCase.fixture_context(scenario)

    results =
      1..8
      |> Enum.map(fn _shard -> Task.async(fn -> WorldSource.stage(capture, root, @at) end) end)
      |> Task.await_many(30_000)

    assert [{:ok, _source}] = Enum.uniq(results)
    assert [_one] = root |> Path.join("job-sources") |> File.ls!()
  end
end
