defmodule Ryker.CoopFleet.ManagedSourcesTest do
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.ManagedSources
  alias Ryker.Work.RepositorySource

  test "one mirror serializes writers without holding another mirror" do
    owner = self()
    storage = Path.join(System.tmp_dir!(), "mirror-lock-#{System.unique_integer([:positive])}")

    # Hold the first lock here; fixture startup is not a 100ms latency contract.
    second =
      ManagedSources.with_mirror_lock(storage, "one", fn ->
        second =
          Task.async(fn ->
            ManagedSources.with_mirror_lock(storage, "one", fn -> send(owner, :same_locked) end)
          end)

        other =
          Task.async(fn ->
            ManagedSources.with_mirror_lock(storage, "two", fn -> send(owner, :other_locked) end)
          end)

        assert_receive :other_locked, 2_000
        refute_receive :same_locked
        Task.await(other)
        second
      end)

    Task.await(second)
    assert_received :same_locked
  end

  # A fetch that stalled inside source preparation held its Work slot for
  # good: git ran with no deadline under a mirror lock that waited forever, so
  # the turn's lease lapsed, the next slot claimed the turn and blocked on the
  # same lock, and every slot touching that repository was consumed.
  test "a stalled fetch is stopped at its deadline and leaves the mirror unlocked" do
    directory = fixture_root()
    primary = remote!(directory, "primary")
    storage = Path.join(directory, "state")
    pid_file = Path.join(directory, "fetch.pid")
    arguments_file = Path.join(directory, "fetch.arguments")

    # Every git command runs for real except the fetch, which hangs.
    git =
      program!(directory, "git", """
      for argument; do
        if [ "$argument" = fetch ]; then
          printf '%s\\n' "$@" > '#{arguments_file}'
          echo $$ > '#{pid_file}'
          exec sleep 30
        fi
      done
      exec '#{System.find_executable("git")}' "$@"
      """)

    preparation =
      Task.async(fn ->
        ManagedSources.prepare_from_remote(
          storage,
          identity("primary", primary, 1),
          "main",
          nil,
          nil,
          git: git,
          # Every git command gets this deadline, the real ones too. At 500 ms
          # a real command ran past it under a loaded gate (2026-09-28) and the
          # fetch never started, so the test failed without testing anything.
          git_timeout_ms: 3_000
        )
      end)

    assert Task.yield(preparation, 30_000) == {:ok, {:error, :coop_worker_source_unavailable}}
    assert File.exists?(pid_file), "the fetch never started: a real git command ran out of time"
    refute pid_file |> File.read!() |> String.trim() |> alive?()

    # A transfer that stalls without hanging git outright is git's to give up:
    # below a byte a second for a minute.
    options = arguments_file |> File.read!() |> String.split("\n", trim: true)
    assert ["-c", "http.lowSpeedLimit=1"] in Enum.chunk_every(options, 2, 1)
    assert ["-c", "http.lowSpeedTime=60"] in Enum.chunk_every(options, 2, 1)

    assert ManagedSources.with_mirror_lock(storage, "primary", fn -> :unlocked end) == :unlocked
  end

  # The mirror lock was :global.trans/2, which retries forever: a preparation
  # behind one that never finished waited with it, holding a Work slot of its own.
  test "a preparation behind a mirror that stays locked gives up at its bound" do
    directory = fixture_root()
    primary = remote!(directory, "primary")
    storage = Path.join(directory, "state")
    owner = self()

    holder =
      Task.async(fn ->
        ManagedSources.with_mirror_lock(storage, "primary", fn ->
          send(owner, :mirror_locked)

          receive do
            :release -> :released
          end
        end)
      end)

    assert_receive :mirror_locked, 2_000

    waiting =
      Task.async(fn ->
        ManagedSources.prepare_from_remote(
          storage,
          identity("primary", primary, 1),
          "main",
          nil,
          nil,
          mirror_lock_wait_ms: 100
        )
      end)

    assert Task.yield(waiting, 5_000) == {:ok, {:error, :coop_worker_source_unavailable}}
    send(holder.pid, :release)
    assert Task.await(holder) == :released
  end

  test "branch selection pins the default and selected identities without a full bundle" do
    directory =
      Path.join(System.tmp_dir!(), "ryker-managed-sources-#{System.unique_integer([:positive])}")

    remote = Path.join(directory, "remote")
    storage = Path.join(directory, "state")
    File.mkdir_p!(remote)
    on_exit(fn -> File.rm_rf!(directory) end)

    git!(["init", "--quiet", remote])
    File.write!(Path.join(remote, "README.md"), "default\n")
    git!(["-C", remote, "add", "README.md"])
    commit!(remote, "default")
    git!(["-C", remote, "branch", "-M", "main"])
    default_commit = git!(["-C", remote, "rev-parse", "HEAD"])

    git!(["-C", remote, "checkout", "--quiet", "-b", "feature"])
    File.write!(Path.join(remote, "README.md"), "selected\n")
    git!(["-C", remote, "add", "README.md"])
    commit!(remote, "selected")
    selected_commit = git!(["-C", remote, "rev-parse", "HEAD"])

    assert {:ok, %{source: source, binding: binding}} =
             ManagedSources.prepare_from_remote(
               storage,
               identity("repo:one", remote, 1, "test/repository"),
               "main",
               %{"kind" => "branch", "name" => "feature"}
             )

    assert source["repository_ref"] == "repo:one"
    assert source["github_repository"] == "test/repository"
    assert source["github_repository_id"] == 1
    assert source["binding"] == binding
    assert source["submodules"] == []
    assert binding["default_commit"] == default_commit
    assert binding["selected_commit"] == selected_commit
    assert binding["base_commit"] == default_commit
    assert binding["selected_ref"] == "refs/heads/feature"
    assert binding["requested"] == %{"kind" => "branch", "name" => "feature"}
    assert {:ok, ^binding} = RepositorySource.parse_binding(binding)
    assert binding["resolved_at"] =~ ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

    mirror = Path.join([storage, "coop-source-mirrors", "repo:one.git"])
    git!(["-C", mirror, "cat-file", "-e", default_commit <> "^{commit}"])
    git!(["-C", mirror, "cat-file", "-e", selected_commit <> "^{commit}"])
    refute File.exists?(Path.join(storage, "coop-job-bundles"))

    assert {:error, :invalid_coop_worker_source} =
             ManagedSources.prepare_from_remote(
               storage,
               identity("../wrong", remote, 1),
               "main",
               nil
             )
  end

  test "an exact commit must still be served by the authenticated remote" do
    directory =
      Path.join(System.tmp_dir!(), "ryker-managed-sources-#{System.unique_integer([:positive])}")

    remote = Path.join(directory, "remote")
    storage = Path.join(directory, "state")
    File.mkdir_p!(remote)
    on_exit(fn -> File.rm_rf!(directory) end)
    git!(["init", "--quiet", remote])

    git!([
      "-C",
      remote,
      "-c",
      "user.name=Ryker",
      "-c",
      "user.email=ryker@example.invalid",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "default"
    ])

    git!(["-C", remote, "branch", "-M", "main"])

    assert {:error, :coop_worker_source_unavailable} =
             ManagedSources.prepare_from_remote(
               storage,
               identity("repo:one", remote, 1, "test/repository"),
               "main",
               %{"kind" => "commit", "sha" => String.duplicate("f", 40)}
             )
  end

  test "nested gitlinks freeze configured identities, not the URLs or default branches" do
    directory = fixture_root()
    leaf = remote!(directory, "leaf")
    middle = remote!(directory, "middle")
    primary = remote!(directory, "primary")
    leaf_commit = git!(["-C", leaf, "rev-parse", "HEAD"])
    leaf_tree = git!(["-C", leaf, "rev-parse", "HEAD^{tree}"])

    submodule!(middle, "nested space", leaf_commit, "git@github.com:example/leaf.git")
    middle_commit = git!(["-C", middle, "rev-parse", "HEAD"])
    submodule!(primary, "vendor/middle", middle_commit, "../middle.git")

    # The selected child is not on its current default branch. The parent
    # gitlink, not the child's branch ancestry, authorizes this exact commit.
    git!(["-C", leaf, "checkout", "--quiet", "--orphan", "unrelated"])
    File.write!(Path.join(leaf, "README.md"), "unrelated default\n")
    git!(["-C", leaf, "add", "README.md"])
    commit!(leaf, "new default")

    resolver = fn
      "example/middle" -> {:ok, identity("middle", middle, 2)}
      "example/leaf" -> {:ok, identity("leaf", leaf, 3)}
      _unknown -> {:error, :unavailable}
    end

    assert {:ok, %{source: source}} =
             ManagedSources.prepare_from_remote(
               Path.join(directory, "state"),
               identity("primary", primary, 1),
               "main",
               nil,
               resolver
             )

    assert [
             %{
               "path" => "vendor/middle",
               "repository_ref" => "middle",
               "github_repository_id" => 2,
               "commit" => ^middle_commit,
               "submodules" => [
                 %{
                   "path" => "nested space",
                   "repository_ref" => "leaf",
                   "github_repository_id" => 3,
                   "commit" => ^leaf_commit,
                   "tree" => ^leaf_tree,
                   "submodules" => []
                 }
               ]
             }
           ] = source["submodules"]

    refute inspect(source) =~ directory
  end

  test "unconfigured repositories and ambiguous or external declarations never gain authority" do
    for {url, expected} <- [
          {"https://evil.invalid/example/child.git", :coop_worker_source_unavailable},
          {"https://github.com@example.invalid/a/b", :coop_worker_source_unavailable},
          {"https://github.com/example/child.git?token=secret", :coop_worker_source_unavailable},
          {"../../outside.git", :coop_worker_source_unavailable},
          # theblitzapp/blitz-core vendors skypjack/entt, which Ryker was never given: every task
          # in its environment spent eight tries in two minutes on it and then could not say
          # why (2026-10-03). No retry fetches it, so the refusal names it at once.
          {"https://github.com/example/unknown.git",
           {:coop_worker_source_refused, "example/primary", "example/unknown"}}
        ] do
      directory = fixture_root()
      primary = remote!(directory, "primary")
      child = remote!(directory, "child")
      submodule!(primary, "vendor/child", git!(["-C", child, "rev-parse", "HEAD"]), url)

      resolver = fn
        "example/child" -> {:ok, identity("child", child, 2)}
        _unknown -> {:error, :submodule_not_configured}
      end

      assert {:error, ^expected} =
               ManagedSources.prepare_from_remote(
                 Path.join(directory, "state"),
                 identity("primary", primary, 1),
                 "main",
                 nil,
                 resolver
               )
    end
  end

  test "GitHub URL spelling does not reject configured dot-prefixed repositories" do
    directory = fixture_root()
    primary = remote!(directory, "primary")
    child = remote!(directory, "child")

    for {url, index} <-
          Enum.with_index([
            "https://GitHub.com/example/.github.git",
            "ssh://git@GitHub.com:22/example/.github.git",
            "git@GitHub.com:example/.github.git"
          ]) do
      submodule!(primary, "vendor/child", git!(["-C", child, "rev-parse", "HEAD"]), url)
      resolver = fn "example/.github" -> {:ok, identity("child", child, 2, "example/.github")} end

      assert {:ok, %{source: source}} =
               ManagedSources.prepare_from_remote(
                 Path.join(directory, "state-#{index}"),
                 identity("primary", primary, 1),
                 "main",
                 nil,
                 resolver
               )

      assert [%{"github_repository" => "example/.github"}] = source["submodules"]
    end
  end

  test "descendants spend the shared budget before another sibling can request a credential" do
    directory = fixture_root()
    leaf = remote!(directory, "leaf")
    middle = remote!(directory, "middle")
    leaf_commit = git!(["-C", leaf, "rev-parse", "HEAD"])
    submodule!(middle, "nested", leaf_commit, "https://github.com/example/leaf.git")
    middle_commit = git!(["-C", middle, "rev-parse", "HEAD"])
    File.mkdir_p!(Path.join([directory, "state", "coop-source-mirrors"]))

    resolver = fn slug ->
      send(self(), {:resolved, slug})

      case slug do
        "example/middle" -> {:ok, identity("middle", middle, 2)}
        "example/leaf" -> {:ok, identity("leaf", leaf, 3)}
        _unknown -> {:error, :unavailable}
      end
    end

    declarations = [
      %{path: "first", commit: middle_commit, repository: "example/middle"},
      %{path: "second", commit: leaf_commit, repository: "example/second"}
    ]

    assert {:error, :submodule_not_authorized} =
             ManagedSources.resolve_submodules(
               Path.join(directory, "state"),
               declarations,
               resolver,
               [],
               0,
               2
             )

    assert_received {:resolved, "example/middle"}
    assert_received {:resolved, "example/leaf"}
    refute_received {:resolved, "example/second"}
  end

  test "gitmodules is pinned data, not executable or included configuration" do
    directory = fixture_root()
    primary = remote!(directory, "primary")
    child = remote!(directory, "child")
    child_commit = git!(["-C", child, "rev-parse", "HEAD"])
    submodule!(primary, "child", child_commit, "ssh://git@github.com:22/example/child.git")
    included = Path.join(directory, "included")
    marker = Path.join(directory, "executed")
    File.write!(included, "[submodule \"child\"]\nurl = https://evil.invalid/child\n")
    git!(["-C", primary, "config", "--file", ".gitmodules", "include.path", included])

    git!([
      "-C",
      primary,
      "config",
      "--file",
      ".gitmodules",
      "submodule.child.update",
      "!touch #{marker}"
    ])

    git!(["-C", primary, "add", ".gitmodules"])
    commit!(primary, "hostile configuration")
    resolver = fn "example/child" -> {:ok, identity("child", child, 2)} end

    prepare = fn ->
      ManagedSources.prepare_from_remote(
        Path.join(directory, "state"),
        identity("primary", primary, 1),
        "main",
        nil,
        resolver
      )
    end

    assert {:ok, %{source: %{"submodules" => [%{"commit" => ^child_commit}]}}} = prepare.()
    refute File.exists?(marker)

    git!([
      "-C",
      primary,
      "config",
      "--file",
      ".gitmodules",
      "--add",
      "submodule.child.url",
      "https://github.com/example/child.git"
    ])

    git!(["-C", primary, "add", ".gitmodules"])
    commit!(primary, "duplicate declaration")
    assert {:error, :coop_worker_source_unavailable} = prepare.()

    git!(["-C", primary, "rm", ".gitmodules"])
    commit!(primary, "missing declaration")
    assert {:error, :coop_worker_source_unavailable} = prepare.()

    assert Path.wildcard(
             Path.join([directory, "state", "coop-source-mirrors", "*", ".coop-gitlinks-*"])
           ) == []
  end

  defp program!(directory, name, body) do
    path = Path.join(directory, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A stopped program may be reaped a moment after it dies.
  defp alive?(os_pid, checks \\ 20) do
    {_output, status} = System.cmd("sh", ["-c", "kill -0 #{os_pid} 2>/dev/null"])

    cond do
      status != 0 -> false
      checks == 0 -> true
      true -> Process.sleep(50) == :ok and alive?(os_pid, checks - 1)
    end
  end

  defp fixture_root do
    directory = Path.join(System.tmp_dir!(), "ryker-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp remote!(directory, name) do
    remote = Path.join(directory, name)
    git!(["init", "--quiet", "--initial-branch=main", remote])
    File.write!(Path.join(remote, "README.md"), name <> "\n")
    git!(["-C", remote, "add", "README.md"])
    commit!(remote, "initial")
    remote
  end

  defp submodule!(repository, path, commit, url) do
    git!(["-C", repository, "update-index", "--add", "--cacheinfo", "160000,#{commit},#{path}"])
    git!(["-C", repository, "config", "--file", ".gitmodules", "submodule.child.path", path])
    git!(["-C", repository, "config", "--file", ".gitmodules", "submodule.child.url", url])
    git!(["-C", repository, "add", ".gitmodules"])
    commit!(repository, "child")
  end

  defp identity(ref, remote, id, github_repository \\ nil),
    do: %{
      repository_ref: ref,
      github_repository: github_repository || "example/" <> ref,
      repository_id: id,
      remote: remote,
      token: nil
    }

  defp commit!(repository, message) do
    git!([
      "-C",
      repository,
      "-c",
      "user.name=Ryker",
      "-c",
      "user.email=ryker@example.invalid",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(arguments) do
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    case System.cmd("git", arguments, stderr_to_stdout: true, env: env) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git failed (#{status}): #{output}")
    end
  end
end
