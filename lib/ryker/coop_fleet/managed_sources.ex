defmodule Ryker.CoopFleet.ManagedSources do
  @moduledoc """
  Resolve a Ryker-authorized GitHub source for a direct worker fetch.

  Ryker pins refs and trees without copying the full working tree. The trusted
  worker receives a separate, short-lived read grant only after command custody
  has checked this immutable identity.
  """
  alias Ryker.ChildEnvironment
  alias Ryker.CoopFleet.JobSpec
  alias Ryker.CoopFleet.Protocol
  alias Ryker.GitHub
  alias Ryker.Settings
  alias Ryker.Work
  require Logger

  @commit ~r/\A[0-9a-f]{40}\z/

  # One git command's deadline. A transfer that stalls is git's own to give up
  # (http.lowSpeedLimit and http.lowSpeedTime); this bounds everything else,
  # and still lets the first mirror of a large repository, minutes long, finish.
  @git_timeout_ms :timer.minutes(30)
  # git removes its lock and temporary files when asked to stop; one still
  # running this long after is killed.
  @git_stop_grace_ms 5_000
  # How long a preparation waits for another one to finish with its mirror.
  @mirror_lock_wait_ms :timer.minutes(30)
  @mirror_lock_poll_ms 250

  # Every failure is the same error to the caller, which retries it; the log
  # says which step failed. On 2026-10-03 a task on tenant gave up on
  # tenantcorp/tenant-infra and nothing said whether the repository, its
  # binding, its token or the fetch was missing.
  @spec prepare(String.t(), String.t(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def prepare(storage_root, repository_ref, requested) do
    with {:inputs, true} <-
           {:inputs,
            is_binary(storage_root) and Path.type(storage_root) == :absolute and
              Protocol.reference?(repository_ref)},
         {:requested, {:ok, requested}} <-
           {:requested, Work.RepositorySource.parse_optional(requested)},
         {:settings, {:ok, snapshot}} <- {:settings, Settings.fetch()},
         {:repository,
          %{
            github_repository: github_repository,
            base_branch: base_branch,
            github_access: :available
          }} <-
           {:repository, Enum.find(snapshot.repositories, &(&1.ref == repository_ref))},
         {:binding, %{name: binding_name, repository_id: repository_id}} <-
           {:binding, Enum.find(snapshot.github_bindings, &(&1.repository_ref == repository_ref))},
         {:token, {:ok, token}} <-
           {:token, GitHub.InstallationTokens.token(binding_name, :source_read)} do
      storage_root
      |> prepare_from_remote(
        %{
          repository_ref: repository_ref,
          github_repository: github_repository,
          repository_id: repository_id,
          token: token,
          remote: "https://github.com/#{github_repository}.git"
        },
        base_branch,
        requested,
        &resolve_repository(snapshot, &1, fn slug ->
          GitHub.PublicRepositories.lookup(snapshot.github.api_url, slug, token)
        end)
      )
      |> log_failure(repository_ref, :fetch)
    else
      {step, failure} ->
        log_failure({:error, failure}, repository_ref, step)
        {:error, :coop_worker_source_unavailable}
    end
  end

  defp log_failure({:error, reason} = error, repository_ref, step) do
    Logger.warning(
      "repository source for #{repository_ref} unavailable at #{step}: " <>
        inspect(reason, limit: 8, printable_limit: 200)
    )

    error
  end

  defp log_failure(result, _repository_ref, _step), do: result

  @doc false
  @spec prepare_from_remote(
          String.t(),
          map(),
          String.t(),
          map() | nil,
          (String.t() -> {:ok, map()} | {:error, atom()}) | nil,
          keyword()
        ) ::
          {:ok, map()} | {:error, atom()}
  def prepare_from_remote(
        storage_root,
        %{
          repository_ref: repository_ref,
          remote: remote,
          github_repository: github_repository,
          repository_id: repository_id
        } = identity,
        base_branch,
        requested,
        resolver \\ nil,
        options \\ []
      ) do
    git = git_runner(options)

    with :ok <- validate_inputs(storage_root, repository_ref, remote, base_branch, requested),
         true <-
           JobSpec.github_repository?(github_repository),
         true <- is_integer(repository_id) and repository_id > 0,
         :ok <- private_mirror_root(storage_root),
         {:ok, prepared, declarations} <-
           with_mirror_lock(
             storage_root,
             repository_ref,
             fn -> prepare_locked(git, storage_root, identity, base_branch, requested) end,
             git.mirror_lock_wait_ms
           ),
         {:ok, modules, _remaining} <-
           resolve_modules(
             git,
             storage_root,
             declarations,
             resolver,
             [{repository_id, prepared.binding["selected_commit"]}],
             0,
             1024
           ) do
      {:ok, put_in(prepared, [:source, "submodules"], modules)}
    else
      false ->
        {:error, :invalid_coop_worker_source}

      {:error, :invalid_coop_worker_source} ->
        {:error, :invalid_coop_worker_source}

      # No retry fetches a submodule from a repository Ryker was never given:
      # the caller stops at once and says which one.
      {:error, {:submodule_not_configured, submodule}} ->
        {:error, {:coop_worker_source_refused, github_repository, submodule}}

      _unavailable ->
        {:error, :coop_worker_source_unavailable}
    end
  end

  @doc """
  Deletes the mirror Ryker keeps of a repository that was removed, under the
  same lock a job's source is prepared under, so a preparation already running
  finishes first; a mirror still locked after as long as a preparation waits
  for one is left in place. Nothing else is Ryker's to delete: each worker
  fetches its own copy for a job.
  """
  @spec remove_mirror(String.t(), String.t()) :: :ok
  def remove_mirror(storage_root, repository_ref) do
    if is_binary(storage_root) and Path.type(storage_root) == :absolute and
         Protocol.reference?(repository_ref) do
      mirror = Path.join([storage_root, "coop-source-mirrors", repository_ref <> ".git"])
      with_mirror_lock(storage_root, repository_ref, fn -> File.rm_rf!(mirror) end)
    end

    :ok
  end

  @doc false
  def with_mirror_lock(storage_root, repository_ref, operation, wait_ms \\ @mirror_lock_wait_ms) do
    # :global identifies a lock by {resource, requester}, not {module, key}.
    lock = {{__MODULE__, Path.expand(storage_root), repository_ref}, self()}
    nodes = [node() | Node.list()]

    if acquire_mirror_lock(lock, nodes, System.monotonic_time(:millisecond) + wait_ms) do
      try do
        operation.()
      after
        :global.del_lock(lock, nodes)
      end
    else
      {:error, :source_mirror_busy}
    end
  end

  # :global.trans/2 retries forever, and a preparation waiting here holds its
  # Work slot, so the wait has a deadline.
  defp acquire_mirror_lock(lock, nodes, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      :global.set_lock(lock, nodes, 0) ->
        true

      remaining <= 0 ->
        false

      true ->
        Process.sleep(min(remaining, @mirror_lock_poll_ms))
        acquire_mirror_lock(lock, nodes, deadline)
    end
  end

  # How one preparation runs git and waits for a mirror. Tests stand a program
  # of their own in for git and shorten the bounds.
  defp git_runner(options) do
    %{
      executable: Keyword.get_lazy(options, :git, fn -> System.find_executable("git") end),
      mirror_lock_wait_ms: Keyword.get(options, :mirror_lock_wait_ms, @mirror_lock_wait_ms),
      timeout_ms: Keyword.get(options, :git_timeout_ms, @git_timeout_ms)
    }
  end

  defp validate_inputs(storage_root, repository_ref, remote, base_branch, requested) do
    if valid_mirror_inputs?(storage_root, repository_ref, remote) and
         valid_selection_inputs?(base_branch, requested),
       do: :ok,
       else: {:error, :invalid_coop_worker_source}
  end

  defp valid_mirror_inputs?(storage_root, repository_ref, remote) do
    is_binary(storage_root) and Path.type(storage_root) == :absolute and
      Protocol.reference?(repository_ref) and is_binary(remote) and remote != ""
  end

  defp valid_selection_inputs?(base_branch, requested) do
    is_binary(base_branch) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/, base_branch) and
      match?({:ok, _}, Work.RepositorySource.parse(requested || Work.RepositorySource.default()))
  end

  defp private_mirror_root(storage_root) do
    root = Path.join(storage_root, "coop-source-mirrors")

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    else
      _unavailable -> {:error, :coop_worker_source_unavailable}
    end
  end

  defp prepare_locked(
         git,
         storage_root,
         %{
           repository_ref: repository_ref,
           remote: remote,
           token: token,
           github_repository: github_repository,
           repository_id: repository_id
         },
         base_branch,
         requested
       ) do
    mirror = Path.join([storage_root, "coop-source-mirrors", repository_ref <> ".git"])
    requested = requested || Work.RepositorySource.default()

    with :ok <- ensure_mirror(git, mirror, remote),
         :ok <- fetch_ref(git, mirror, "refs/heads/" <> base_branch, token),
         {:ok, default_commit} <- commit_at(git, mirror, "refs/heads/" <> base_branch),
         {:ok, selected_ref, selected_commit} <-
           select(git, mirror, requested, default_commit, base_branch, token),
         {:ok, base_commit} <- merge_base(git, mirror, default_commit, selected_commit),
         {:ok, admitted_tree} <-
           git_value(
             git,
             mirror,
             ["rev-parse", "--verify", selected_commit <> "^{tree}"],
             @commit
           ),
         {:ok, declarations} <-
           submodule_declarations(git, mirror, selected_commit, github_repository, token) do
      binding =
        source_binding(
          requested,
          "refs/heads/" <> base_branch,
          default_commit,
          selected_ref,
          selected_commit,
          base_commit,
          admitted_tree
        )

      {:ok,
       %{
         source: %{
           "repository_ref" => repository_ref,
           "github_repository" => github_repository,
           "github_repository_id" => repository_id,
           "binding" => binding,
           "submodules" => []
         },
         binding: binding
       }, declarations}
    else
      _failure -> {:error, :coop_worker_source_unavailable}
    end
  end

  defp ensure_mirror(git, mirror, remote) do
    case File.lstat(mirror) do
      {:error, :enoent} ->
        with :ok <- git(git, nil, ["init", "--quiet", "--bare", mirror], nil) do
          git(git, mirror, ["remote", "add", "origin", remote], nil)
        end

      {:ok, %File.Stat{type: :directory}} ->
        confirm_remote(git, mirror, remote)

      _wrong ->
        {:error, :mirror}
    end
  end

  defp confirm_remote(git, mirror, remote) do
    with {:ok, ^remote} <- git_output(git, mirror, ["remote", "get-url", "origin"], nil),
         do: :ok
  end

  defp fetch_ref(git, mirror, ref, token) do
    git(
      git,
      mirror,
      [
        "fetch",
        "--quiet",
        "--filter=blob:none",
        "--no-tags",
        "--force",
        "origin",
        "+#{ref}:#{ref}"
      ],
      token
    )
  end

  defp commit_at(git, mirror, ref),
    do: git_value(git, mirror, ["rev-parse", "--verify", ref <> "^{commit}"], @commit)

  defp select(_git, _mirror, %{"kind" => "default"}, default_commit, base_branch, _token),
    do: {:ok, "refs/heads/" <> base_branch, default_commit}

  defp select(git, mirror, %{"kind" => "branch", "name" => name}, _default, _branch, token) do
    ref = "refs/heads/" <> name

    with :ok <- fetch_ref(git, mirror, ref, token),
         {:ok, commit} <- commit_at(git, mirror, ref),
         do: {:ok, ref, commit}
  end

  defp select(git, mirror, %{"kind" => "pull_request", "number" => number}, _, _, token) do
    ref = "refs/pull/#{number}/head"

    with :ok <- fetch_ref(git, mirror, ref, token),
         {:ok, commit} <- commit_at(git, mirror, ref),
         do: {:ok, ref, commit}
  end

  defp select(git, mirror, %{"kind" => "commit", "sha" => sha}, _default, _branch, token) do
    with :ok <-
           git(
             git,
             mirror,
             ["fetch", "--quiet", "--filter=blob:none", "--no-tags", "origin", sha],
             token
           ),
         {:ok, ^sha} <- commit_at(git, mirror, sha) do
      {:ok, nil, sha}
    end
  end

  defp merge_base(git, mirror, default_commit, selected_commit),
    do: git_value(git, mirror, ["merge-base", default_commit, selected_commit], @commit)

  @doc """
  The repository a submodule comes from: one Ryker was given, read through its
  GitHub binding; else a public one, which anyone may read, fetched without
  credentials (tenantcorp/tenant-core vendors skypjack/entt, 2026-10-03).
  `public_lookup` asks GitHub whether a repository Ryker was never given is
  public. A repository Ryker was given but cannot reach stays refused: its
  access is the operator's to fix.
  """
  @spec resolve_repository(map(), String.t(), (String.t() -> term())) ::
          {:ok, map()} | {:error, atom()}
  def resolve_repository(snapshot, slug, public_lookup) do
    snapshot.repositories
    |> Enum.filter(&(String.downcase(&1.github_repository || "") == String.downcase(slug)))
    |> case do
      [] -> public_repository(slug, public_lookup)
      configured -> configured_repository(snapshot, configured)
    end
  end

  # The ref a public repository Ryker was never given has in a job. No
  # configured repository's ref has a colon, so the two never meet.
  @spec public_ref(String.t()) :: String.t()
  defp public_ref(full_name), do: "public:" <> String.replace(full_name, "/", ":")

  defp public_repository(slug, public_lookup) do
    case public_lookup.(slug) do
      {:ok, %{full_name: full_name, id: id}} ->
        {:ok,
         %{
           repository_ref: public_ref(full_name),
           github_repository: full_name,
           repository_id: id,
           remote: "https://github.com/#{full_name}.git",
           token: nil
         }}

      {:error, :not_public} ->
        {:error, :submodule_not_configured}

      _unavailable ->
        {:error, :submodule_not_authorized}
    end
  end

  defp configured_repository(snapshot, repositories) do
    with [%{ref: ref, github_repository: repository, github_access: :available}] <- repositories,
         [%{name: name, repository_id: id}] <-
           Enum.filter(snapshot.github_bindings, &(&1.repository_ref == ref)) do
      case GitHub.InstallationTokens.token(name, :source_read) do
        {:ok, token} ->
          {:ok,
           %{
             repository_ref: ref,
             github_repository: repository,
             repository_id: id,
             remote: "https://github.com/#{repository}.git",
             token: token
           }}

        _unavailable ->
          {:error, :submodule_not_authorized}
      end
    else
      _not_configured -> {:error, :submodule_not_configured}
    end
  end

  @doc false
  def resolve_submodules(root, declarations, resolver, ancestors, depth, remaining),
    do: resolve_modules(git_runner([]), root, declarations, resolver, ancestors, depth, remaining)

  defp resolve_modules(_git, _root, [], _resolver, _ancestors, _depth, remaining)
       when remaining >= 0,
       do: {:ok, [], remaining}

  defp resolve_modules(git, root, declarations, resolver, ancestors, depth, remaining)
       when is_function(resolver, 1) and depth < 16 and length(declarations) <= remaining do
    Enum.reduce_while(declarations, {:ok, [], remaining}, fn declaration, {:ok, modules, left} ->
      with true <- left > 0,
           {:ok, identity} <- resolve_module(resolver, declaration),
           false <- {identity.repository_id, declaration.commit} in ancestors,
           {:ok, tree, nested} <- pin_submodule(git, root, identity, declaration.commit),
           {:ok, children, left} <-
             resolve_modules(
               git,
               root,
               nested,
               resolver,
               [{identity.repository_id, declaration.commit} | ancestors],
               depth + 1,
               left - 1
             ) do
        module = %{
          "path" => declaration.path,
          "commit" => declaration.commit,
          "tree" => tree,
          "repository_ref" => identity.repository_ref,
          "github_repository" => identity.github_repository,
          "github_repository_id" => identity.repository_id,
          "submodules" => children
        }

        {:cont, {:ok, [module | modules], left}}
      else
        {:error, {:submodule_not_configured, submodule}} ->
          {:halt, {:error, {:submodule_not_configured, submodule}}}

        _unavailable ->
          {:halt, {:error, :submodule_not_authorized}}
      end
    end)
    |> case do
      {:ok, modules, left} -> {:ok, Enum.reverse(modules), left}
      error -> error
    end
  end

  defp resolve_modules(_git, _root, _declarations, _resolver, _ancestors, _depth, _remaining),
    do: {:error, :submodule_manifest_limit}

  # tenantcorp/tenant-core vendors skypjack/entt, which no GitHub App
  # installation of theirs can reach (2026-10-03). The worker stages every
  # gitlink a source declares, so that source cannot be staged at all.
  defp resolve_module(resolver, declaration) do
    case resolver.(declaration.repository) do
      {:ok, identity} ->
        {:ok, identity}

      {:error, :submodule_not_configured} ->
        {:error, {:submodule_not_configured, declaration.repository}}

      _unavailable ->
        {:error, :submodule_not_authorized}
    end
  end

  defp pin_submodule(git, root, identity, commit) do
    with_mirror_lock(
      root,
      identity.repository_ref,
      fn -> pin_locked(git, root, identity, commit) end,
      git.mirror_lock_wait_ms
    )
  end

  defp pin_locked(git, root, identity, commit) do
    mirror = Path.join([root, "coop-source-mirrors", identity.repository_ref <> ".git"])
    pinned = %{"kind" => "commit", "sha" => commit}

    with :ok <- ensure_mirror(git, mirror, identity.remote),
         {:ok, nil, ^commit} <- select(git, mirror, pinned, nil, nil, identity.token),
         {:ok, tree} <- git_value(git, mirror, ["rev-parse", commit <> "^{tree}"], @commit),
         {:ok, children} <-
           submodule_declarations(git, mirror, commit, identity.github_repository, identity.token) do
      {:ok, tree, children}
    end
  end

  defp submodule_declarations(git, mirror, commit, repository, token) do
    with {:ok, links} <- read_gitlinks(git, mirror, commit, token) do
      if links == [],
        do: {:ok, []},
        else: declared_links(git, mirror, commit, repository, token, links)
    end
  end

  # The primary tree can contain millions of ordinary files. Spool its metadata
  # while retaining only bounded gitlink declarations, never the full listing.
  defp read_gitlinks(git, mirror, commit, token) do
    path = Path.join(mirror, ".coop-gitlinks-" <> Ecto.UUID.generate())

    with {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        with {:ok, _stream} <-
               git_raw(
                 git,
                 mirror,
                 ["ls-tree", "-r", "-z", commit],
                 token,
                 IO.binstream(file, 65_536)
               ),
             :ok <- File.close(file) do
          path
          |> File.stream!(65_536)
          |> Enum.reduce_while({:ok, [], ""}, fn chunk, {:ok, links, pending} ->
            entries = String.split(pending <> chunk, <<0>>)
            pending = List.last(entries)

            with true <- byte_size(pending) <= 8192,
                 {:ok, links} <- gitlinks(Enum.drop(entries, -1), links) do
              {:cont, {:ok, links, pending}}
            else
              _invalid -> {:halt, {:error, :invalid_gitlink}}
            end
          end)
          |> case do
            {:ok, links, ""} -> {:ok, Enum.sort_by(links, & &1.path)}
            _invalid -> {:error, :invalid_gitlink}
          end
        end
      after
        File.close(file)
        File.rm(path)
      end
    end
  end

  defp gitlinks(entries, links) do
    Enum.reduce_while(entries, {:ok, links}, fn entry, {:ok, links} ->
      gitlink_entry(String.split(entry, "\t", parts: 2), links)
    end)
  end

  defp gitlink_entry(["160000 commit " <> commit, path], links) do
    if Regex.match?(@commit, commit) and JobSpec.submodule_path?(path) and length(links) < 1024,
      do: {:cont, {:ok, [%{path: path, commit: commit} | links]}},
      else: {:halt, {:error, :invalid_gitlink}}
  end

  defp gitlink_entry(_ordinary, links), do: {:cont, {:ok, links}}

  defp declared_links(git, mirror, commit, repository, token, links) do
    with {:ok, entry} <-
           git_raw(git, mirror, ["ls-tree", "-z", commit, "--", ".gitmodules"], token),
         true <- Regex.match?(~r/\A100(?:644|755) blob [a-f0-9]{40}\t\.gitmodules\x00\z/, entry),
         {:ok, size} <-
           git_output(git, mirror, ["cat-file", "-s", commit <> ":.gitmodules"], token),
         {size, ""} when size <= 262_144 <- Integer.parse(size),
         {:ok, config} <-
           git_raw(
             git,
             mirror,
             ["config", "--no-includes", "--null", "--blob", commit <> ":.gitmodules", "--list"],
             token
           ),
         {:ok, declarations} <- parse_modules(config) do
      bind_declarations(links, declarations, repository)
    else
      _invalid -> {:error, :invalid_submodule_declaration}
    end
  end

  defp bind_declarations(links, declarations, repository) do
    Enum.reduce_while(links, {:ok, []}, fn link, {:ok, result} ->
      with [%{"url" => url}] <-
             Enum.filter(Map.values(declarations), &(&1["path"] == link.path)),
           {:ok, slug} <- submodule_repository(repository, url) do
        {:cont, {:ok, [Map.put(link, :repository, slug) | result]}}
      else
        _invalid -> {:halt, {:error, :invalid_submodule_declaration}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      error -> error
    end
  end

  defp parse_modules(config) do
    config
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, modules} ->
      parse_module_entry(String.split(entry, "\n", parts: 2), modules)
    end)
  end

  defp parse_module_entry([key, value], modules) do
    case Regex.run(~r/\Asubmodule\.(.+)\.(path|url)\z/, key) do
      [_, name, field] ->
        fields = Map.get(modules, name, %{})

        if Map.has_key?(fields, field),
          do: {:halt, {:error, :duplicate_submodule_declaration}},
          else: {:cont, {:ok, Map.put(modules, name, Map.put(fields, field, value))}}

      _unrelated ->
        {:cont, {:ok, modules}}
    end
  end

  defp parse_module_entry(_unrelated, modules), do: {:cont, {:ok, modules}}

  defp submodule_repository(parent, "git@" <> address) do
    case String.split(address, ":", parts: 2) do
      [host, path] -> submodule_repository(parent, "ssh://git@#{host}/#{path}")
      _invalid -> {:error, :submodule_not_github}
    end
  end

  defp submodule_repository(parent, url) do
    url =
      if String.starts_with?(url, ["../", "./"]),
        do: URI.merge("https://github.com/#{parent}.git/", url) |> URI.to_string(),
        else: url

    case URI.new(url) do
      {:ok,
       %URI{
         scheme: scheme,
         host: host,
         port: port,
         path: "/" <> path,
         userinfo: userinfo,
         query: nil,
         fragment: nil
       }}
      when is_binary(host) ->
        slug =
          if String.ends_with?(path, ".git"),
            do: binary_part(path, 0, byte_size(path) - 4),
            else: path

        if String.downcase(host) == "github.com" and
             {scheme, port, userinfo} in [
               {"https", 443, nil},
               {"ssh", nil, "git"},
               {"ssh", 22, "git"}
             ] and
             JobSpec.github_repository?(slug),
           do: {:ok, slug},
           else: {:error, :submodule_not_github}

      _invalid ->
        {:error, :submodule_not_github}
    end
  end

  defp source_binding(
         requested,
         default_ref,
         default_commit,
         selected_ref,
         selected_commit,
         base_commit,
         tree
       ) do
    %{
      "version" => 1,
      "kind" => requested["kind"],
      "requested" => requested,
      "remote_identity" => "origin",
      "default_ref" => default_ref,
      "default_commit" => default_commit,
      "selected_ref" => selected_ref,
      "selected_commit" => selected_commit,
      "base_commit" => base_commit,
      "admitted_tree" => tree,
      "resolved_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
    }
    |> maybe_put_pull_request(requested)
  end

  defp maybe_put_pull_request(binding, %{"kind" => "pull_request", "number" => number}),
    do: Map.put(binding, "pull_request_number", number)

  defp maybe_put_pull_request(binding, _requested), do: binding

  defp git_value(git, directory, arguments, pattern) do
    with {:ok, value} <- git_output(git, directory, arguments, nil),
         true <- Regex.match?(pattern, value) do
      {:ok, value}
    else
      _failure -> {:error, :git}
    end
  end

  defp git(git, directory, arguments, token) do
    case git_output(git, directory, arguments, token) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_output(git, directory, arguments, token) do
    with {:ok, output} <- git_raw(git, directory, arguments, token),
         do: {:ok, String.trim(output)}
  end

  defp git_raw(git, directory, arguments, token, into \\ "") do
    case open_git(git, directory, arguments, token) do
      {:ok, port} ->
        {initial, collect} = Collectable.into(into)
        deadline = System.monotonic_time(:millisecond) + git.timeout_ms
        await_git(port, os_pid(port), deadline, initial, collect)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_git(git, directory, arguments, token) do
    arguments = [
      "--no-replace-objects",
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "fetch.recurseSubmodules=false",
      "-c",
      "credential.helper=",
      "-c",
      "protocol.ext.allow=never",
      # Slower than a byte a second for a minute, a transfer has stalled.
      "-c",
      "http.lowSpeedLimit=1",
      "-c",
      "http.lowSpeedTime=60" | arguments
    ]

    options = [
      :binary,
      :exit_status,
      :hide,
      :use_stdio,
      args: arguments,
      env: port_environment(token)
    ]

    options = if directory, do: [{:cd, directory} | options], else: options
    {:ok, Port.open({:spawn_executable, git.executable}, options)}
  rescue
    _unstartable in [ArgumentError, ErlangError] -> {:error, :git}
  end

  defp await_git(port, os_pid, deadline, acc, collect) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        await_git(port, os_pid, deadline, collect.(acc, {:cont, data}), collect)

      {^port, {:exit_status, 0}} ->
        {:ok, collect.(acc, :done)}

      {^port, {:exit_status, _status}} ->
        collect.(acc, :halt)
        {:error, :git}
    after
      remaining ->
        stop_git(port, os_pid)
        collect.(acc, :halt)
        {:error, :git_timeout}
    end
  end

  # Closing the port does not stop git. It is asked to stop, which lets it
  # remove its lock and temporary files, and killed if it has not after a
  # grace; either signal goes to its exact process id, never a name or pattern.
  defp stop_git(port, os_pid) do
    signal(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @git_stop_grace_ms -> signal(os_pid, "KILL")
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush_git(port)
  end

  defp signal(nil, _signal), do: :ok

  defp signal(os_pid, signal) when is_integer(os_pid),
    do: System.cmd("kill", ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true)

  defp flush_git(port) do
    receive do
      {^port, _message} -> flush_git(port)
      {:EXIT, ^port, _reason} -> flush_git(port)
    after
      0 -> :ok
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  # Git gets no inherited GIT_ or GCM_ setting and none of Ryker's keys
  # (`Ryker.ChildEnvironment`), only these.
  defp port_environment(token) do
    ChildEnvironment.port([
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TEMPLATE_DIR", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", if(token, do: "1", else: "0")},
      {"GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader"},
      {"GIT_CONFIG_VALUE_0", if(token, do: git_authorization(token))}
    ])
  end

  @doc """
  The header git sends to GitHub with an installation token. GitHub's git
  endpoint takes the token only as the password of the `x-access-token` user
  and refuses it as a Bearer token, for public repositories too.
  """
  @spec git_authorization(String.t()) :: String.t()
  def git_authorization(token) when is_binary(token),
    do: "Authorization: Basic " <> Base.encode64("x-access-token:" <> token)
end
