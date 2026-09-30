defmodule Ryker.Evals.WorldSource do
  @moduledoc """
  Stages a scenario's captured repository as a Coop job source for the dedicated eval Coop.

  A Coop job source is always a GitHub repository, fetched by a fleet worker with a credential
  the controller issues. The eval Coop is a local daemon instead: its session service reads every
  job source from its own private state, `job-sources/<key>/` holding the checkout and the
  `source.json` receipt, where the key is the SHA-256 of the source's Go JSON. So the harness
  stages the captured files there itself. Nothing is fetched and no credential exists.

  The checkout is one commit with a fixed identity and date, so the same captured files always
  give the same commit, tree and key, and a run finds its source already staged.

  Rivals (2026-09-30): since eval jobs lost their repositories, Work had no configured target
  for `request_task` and rightly asked for one, so the scenario that proves engineering task
  offers could never pass.
  """

  @github_owner "ryker-eval"
  @identity [
    {"GIT_AUTHOR_NAME", "Ryker eval"},
    {"GIT_AUTHOR_EMAIL", "eval@ryker.invalid"},
    {"GIT_COMMITTER_NAME", "Ryker eval"},
    {"GIT_COMMITTER_EMAIL", "eval@ryker.invalid"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"}
  ]

  @doc """
  Stages `capture` (`Ryker.Evals.WorldCase.fixture_context/1`) under the eval Coop's
  `state_root` and returns the job source that names it. `at` dates the commit and the binding.
  """
  @spec stage(map(), String.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def stage(%{"repository" => ref, "files" => [_ | _] = files} = capture, state_root, at) do
    parent = Path.join(state_root, "job-sources")

    with :ok <- private_directory(parent),
         {:ok, staging} <- staging_directory(parent) do
      try do
        repository = Path.join(staging, "repository")

        with {:ok, commit, tree} <- commit(repository, files, capture, at),
             source = source(ref, commit, tree, at),
             final = Path.join(parent, staging_key(source)),
             :ok <- place(staging, final, source) do
          {:ok, source}
        end
      after
        File.rm_rf(staging)
      end
    end
  end

  def stage(_capture, _state_root, _at), do: {:error, :invalid_world_source}

  @doc "The job source for one captured checkout, in Ryker's job document shape."
  @spec source(String.t(), String.t(), String.t(), DateTime.t()) :: map()
  def source(ref, commit, tree, at) do
    %{
      "repository_ref" => ref,
      "github_repository" => "#{@github_owner}/#{ref}",
      "github_repository_id" => 1,
      "binding" => %{
        "version" => 1,
        "kind" => "default",
        "requested" => %{"kind" => "default"},
        "remote_identity" => "origin",
        "default_ref" => "refs/heads/main",
        "default_commit" => commit,
        "selected_ref" => "refs/heads/main",
        "selected_commit" => commit,
        "base_commit" => commit,
        "admitted_tree" => tree,
        "resolved_at" => DateTime.to_iso8601(DateTime.truncate(at, :second))
      },
      "submodules" => []
    }
  end

  @doc """
  Coop's staging key: the SHA-256 of the source as Go's `json.Marshal` writes it, fields in
  struct order, which is what `workerproto.JobSource.StagingKey` hashes.
  """
  @spec staging_key(map()) :: String.t()
  def staging_key(source),
    do: source |> go_json() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc false
  def go_json(%{"binding" => binding} = source) do
    requested = %Jason.OrderedObject{values: [{"kind", binding["requested"]["kind"]}]}

    binding =
      %Jason.OrderedObject{
        values:
          Enum.map(
            ~w(version kind requested remote_identity default_ref default_commit selected_ref selected_commit base_commit admitted_tree resolved_at),
            &{&1, if(&1 == "requested", do: requested, else: binding[&1])}
          )
      }

    %Jason.OrderedObject{
      values: [
        {"repository_ref", source["repository_ref"]},
        {"github_repository", source["github_repository"]},
        {"github_repository_id", source["github_repository_id"]},
        {"binding", binding},
        {"submodules", []}
      ]
    }
    |> Jason.encode!()
  end

  defp commit(repository, files, capture, at) do
    date = DateTime.to_iso8601(DateTime.truncate(at, :second))
    env = [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date} | @identity]
    message = "Captured #{capture["repository"]} at #{capture["captured_revision"]}"

    with :ok <- git(["init", "-q", "-b", "main", "--template=", repository], ".", env),
         :ok <- write_files(repository, files),
         :ok <- git(["add", "--all"], repository, env),
         :ok <- git(["commit", "-q", "--no-gpg-sign", "-m", message], repository, env),
         {:ok, commit} <- rev_parse(repository, "HEAD", env),
         {:ok, tree} <- rev_parse(repository, "HEAD^{tree}", env),
         :ok <- File.chmod(repository, 0o700) do
      {:ok, commit, tree}
    end
  end

  defp write_files(repository, files) do
    Enum.reduce_while(files, :ok, fn %{"path" => path, "data" => data}, :ok ->
      target = Path.join(repository, path)

      if Path.type(path) == :relative and not String.contains?(path, ".."),
        do:
          {:cont, with(:ok <- File.mkdir_p(Path.dirname(target)), do: File.write(target, data))},
        else: {:halt, {:error, :invalid_world_source_path}}
    end)
  end

  # A key names its exact bytes, so a slot already staged holds this commit: keep it.
  defp place(staging, final, source) do
    if File.dir?(final), do: :ok, else: publish(staging, final, source)
  end

  defp publish(staging, final, source) do
    receipt = Path.join(staging, "source.json")

    with :ok <- File.write(receipt, go_json(source)),
         :ok <- File.chmod(receipt, 0o600),
         :ok <- File.chmod(staging, 0o700) do
      staging |> File.rename(final) |> placed(final)
    end
  end

  # Parallel shards stage the same scenario at once; the rename that loses finds the slot
  # another shard just staged.
  defp placed(:ok, _final), do: :ok
  defp placed(error, final), do: if(File.dir?(final), do: :ok, else: error)

  defp private_directory(path) do
    with :ok <- File.mkdir_p(path), do: File.chmod(path, 0o700)
  end

  defp staging_directory(parent) do
    path =
      Path.join(
        parent,
        ".ryker-eval-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    with :ok <- File.mkdir(path), :ok <- File.chmod(path, 0o700), do: {:ok, path}
  end

  defp rev_parse(repository, revision, env) do
    case System.cmd("git", ["rev-parse", revision],
           cd: repository,
           env: env,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, {:world_source_git, String.slice(output, 0, 500)}}
    end
  end

  defp git(arguments, directory, env) do
    case System.cmd("git", arguments, cd: directory, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:world_source_git, String.slice(output, 0, 500)}}
    end
  end
end
