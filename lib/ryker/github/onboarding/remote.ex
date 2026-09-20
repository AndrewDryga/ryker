defmodule Ryker.GitHub.Onboarding.Remote do
  @moduledoc "Bounded GitHub source scan and idempotent RYKER.md pull-request publisher."
  @behaviour Ryker.GitHub.Onboarding

  alias Ryker.Delivery.JSONClient
  alias Ryker.GitHub.InstallationTokens

  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "ryker"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @branch "ryker/repository-knowledge"
  @maximum_tree_entries 10_000
  @maximum_source_bytes 128_000
  @source_names ~w(README.md README.rst README.txt AGENTS.md CONTRIBUTING.md Makefile mix.exs package.json pyproject.toml go.mod Cargo.toml Gemfile)

  @impl true
  def pin(binding, repository) do
    with {:ok, client} <- client(binding.name),
         {:ok, response} <-
           request(
             client,
             :get,
             "/repos/#{repository.github_repository}/git/ref/heads/#{encode_ref(repository.base_branch)}"
           ) do
      case response do
        %{status: 200, body: %{"object" => %{"sha" => sha}}} when is_binary(sha) ->
          commit(sha)

        %{status: 404} ->
          {:error, {:github_onboarding, :not_found}}

        %{status: status} when status in [401, 403] ->
          {:error, {:github_onboarding, :permission}}

        %{status: 409} ->
          {:error, :repository_empty}

        _other ->
          {:error, {:github_onboarding, :response}}
      end
    end
  end

  @impl true
  def scan(binding, repository, source_commit) do
    with {:ok, client} <- client(binding.name),
         {:ok, tree} <- tree(client, repository.github_repository, source_commit),
         :ok <- bounded_tree(tree),
         {:ok, existing} <- file(client, repository.github_repository, "RYKER.md", source_commit) do
      if existing == :not_found do
        sources = source_files(client, repository.github_repository, source_commit, tree)

        {:ok,
         %{
           content: document(repository.github_repository, source_commit, tree, sources),
           status: :proposed
         }}
      else
        {:ok, %{content: existing.text, status: :accepted}}
      end
    end
  end

  @impl true
  def publish(binding, repository, source_commit, content) do
    with {:ok, client} <- client(binding.name),
         {:ok, owner} <- owner(repository.github_repository),
         {:ok, current} <- open_pull(client, repository.github_repository, owner) do
      case current do
        %{"html_url" => url} when is_binary(url) ->
          {:ok, %{url: url}}

        :not_found ->
          publish_new(client, repository, source_commit, content, owner)
      end
    end
  end

  defp publish_new(client, repository, source_commit, content, owner) do
    with {:ok, branch} <- branch(client, repository.github_repository, source_commit),
         :ok <- available_branch(branch),
         :ok <- write_knowledge(client, repository.github_repository, content),
         {:ok, pull} <-
           request(client, :post, "/repos/#{repository.github_repository}/pulls", %{
             "base" => repository.base_branch,
             "body" =>
               "Adds source-grounded repository knowledge scanned from `#{source_commit}`. Review and edit it before merging; setup does not auto-merge this pull request.",
             "draft" => true,
             "head" => @branch,
             "title" => "Add Ryker repository knowledge"
           }) do
      case pull do
        %{status: 201, body: %{"html_url" => url}} when is_binary(url) -> {:ok, %{url: url}}
        %{status: status} when status in [401, 403] -> {:error, {:github_onboarding, :permission}}
        _other -> reconcile_pull(client, repository.github_repository, owner)
      end
    end
  end

  defp branch(client, repository, source_commit) do
    path = "/repos/#{repository}/git/ref/heads/#{encode_ref(@branch)}"

    case request(client, :get, path) do
      {:ok, %{status: 200}} -> {:ok, :existing}
      {:ok, %{status: 404}} -> create_branch(client, repository, source_commit)
      {:ok, %{status: status}} when status in [401, 403] -> permission_error()
      {:ok, _other} -> branch_error()
      {:error, _reason} = error -> error
    end
  end

  defp create_branch(client, repository, source_commit) do
    case request(client, :post, "/repos/#{repository}/git/refs", %{
           "ref" => "refs/heads/#{@branch}",
           "sha" => source_commit
         }) do
      {:ok, %{status: 201}} -> {:ok, :created}
      {:ok, %{status: status}} when status in [401, 403] -> permission_error()
      {:ok, _other} -> branch_error()
      {:error, _reason} = error -> error
    end
  end

  defp permission_error, do: {:error, {:github_onboarding, :permission}}
  defp branch_error, do: {:error, {:github_onboarding, :branch}}

  # The stable setup branch is also the restart checkpoint. If a crash happened
  # after the file write but before PR creation, continuing from it is the only
  # idempotent recovery. A closed PR leaves the repository in `ready`; only an
  # explicit operator retry returns it to this path.
  defp available_branch(:existing), do: :ok
  defp available_branch(:created), do: :ok

  defp write_knowledge(client, repository, content) do
    case file(client, repository, "RYKER.md", @branch) do
      {:ok, :not_found} ->
        with {:ok, response} <-
               request(client, :put, "/repos/#{repository}/contents/RYKER.md", %{
                 "branch" => @branch,
                 "content" => Base.encode64(content),
                 "message" => "Add Ryker repository knowledge"
               }) do
          file_written(response)
        end

      {:ok, %{text: _existing}} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp file_written(%{status: status}) when status in [200, 201], do: :ok

  defp file_written(%{status: status}) when status in [401, 403],
    do: {:error, {:github_onboarding, :permission}}

  defp file_written(_response), do: {:error, {:github_onboarding, :write}}

  defp reconcile_pull(client, repository, owner) do
    case open_pull(client, repository, owner) do
      {:ok, %{"html_url" => url}} -> {:ok, %{url: url}}
      _other -> {:error, {:github_onboarding, :pull_request}}
    end
  end

  defp open_pull(client, repository, owner) do
    query =
      URI.encode_query(%{"head" => "#{owner}:#{@branch}", "per_page" => 1, "state" => "open"})

    with {:ok, response} <- request(client, :get, "/repos/#{repository}/pulls?#{query}") do
      case response do
        %{status: 200, body: [pull | _]} -> {:ok, pull}
        %{status: 200, body: []} -> {:ok, :not_found}
        %{status: status} when status in [401, 403] -> {:error, {:github_onboarding, :permission}}
        _other -> {:error, {:github_onboarding, :pull_request}}
      end
    end
  end

  defp tree(client, repository, source_commit) do
    path = "/repos/#{repository}/git/trees/#{source_commit}?recursive=1"

    case request(client, :get, path) do
      {:ok, %{status: 200, body: %{"tree" => entries} = body}} when is_list(entries) ->
        if body["truncated"] == true,
          do: {:error, :repository_too_large},
          else: {:ok, entries}

      {:ok, %{status: status}} when status in [401, 403] ->
        permission_error()

      {:ok, %{status: 404}} ->
        {:error, {:github_onboarding, :not_found}}

      {:ok, _other} ->
        {:error, {:github_onboarding, :tree}}

      {:error, _reason} = error ->
        error
    end
  end

  defp bounded_tree(entries) when length(entries) <= @maximum_tree_entries, do: :ok
  defp bounded_tree(_entries), do: {:error, :repository_too_large}

  defp source_files(client, repository, source_commit, tree) do
    paths = MapSet.new(tree, & &1["path"])

    @source_names
    |> Enum.filter(&MapSet.member?(paths, &1))
    |> Enum.take(12)
    |> Enum.flat_map(fn path ->
      case file(client, repository, path, source_commit) do
        {:ok, %{text: text}} -> [{path, text}]
        _unavailable -> []
      end
    end)
    |> Map.new()
  end

  defp file(client, repository, path, source_commit) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))

    query = URI.encode_query(%{"ref" => source_commit})

    case request(client, :get, "/repos/#{repository}/contents/#{encoded}?#{query}") do
      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64"}}}
      when is_binary(content) ->
        decode_file(content)

      {:ok, %{status: status}} when status in [401, 403] ->
        permission_error()

      {:ok, _unavailable} ->
        {:error, :source_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_file(content) do
    with {:ok, decoded} <- Base.decode64(String.replace(content, "\n", "")),
         true <- byte_size(decoded) <= @maximum_source_bytes and String.valid?(decoded) do
      {:ok, %{text: decoded}}
    else
      _too_large_or_invalid -> {:error, :source_unavailable}
    end
  end

  defp document(repository, source_commit, tree, sources) do
    directories = top_directories(tree)
    languages = languages(tree)
    commands = commands(sources)
    purpose = purpose(sources)
    source_url = "https://github.com/#{repository}/blob/#{source_commit}"

    """
    # RYKER.md

    > Repository knowledge generated from `#{source_commit}`. Facts below come from the linked files. Commands are detected, not executed, unless a later note says otherwise.

    ## Purpose

    #{purpose}

    ## Repository map

    #{bullets(directories, fn directory -> "[`#{directory}/`](#{source_url}/#{directory})" end, "No top-level source directories were found.")}

    ## Languages and dependencies

    #{bullets(languages, fn {language, count} -> "#{language}: #{count} source files" end, "No recognized source-language files were found.")}

    ## Setup, build and test

    #{bullets(commands, &"`#{&1}` (detected from repository files; not run during setup)", "No standard setup or test command was identified. Confirm the expected workflow with the maintainers.")}

    ## CI and release

    #{ci_summary(tree, source_url)}

    ## Conventions and operational notes

    #{guidance(sources, source_url)}

    ## Unresolved questions

    - Confirm production deployment ownership and verification steps if they are not documented in the linked sources.
    - Confirm any required secrets, external services, or generated files before running the detected commands.
    """
  end

  defp purpose(sources) do
    readme = Enum.find_value(["README.md", "README.rst", "README.txt"], &Map.get(sources, &1))

    case readme do
      nil ->
        "No README purpose statement was available. Inspect the repository map and confirm its role."

      text ->
        text
        |> String.split(~r/\n\s*\n/, trim: true)
        |> Enum.reject(&String.starts_with?(String.trim(&1), ["#", "!", "[!"]))
        |> List.first()
        |> case do
          nil -> "The README did not contain a short prose purpose statement."
          paragraph -> paragraph |> String.replace(~r/\s+/, " ") |> String.slice(0, 600)
        end
    end
  end

  defp top_directories(tree) do
    tree
    |> Enum.filter(&(&1["type"] == "tree" and is_binary(&1["path"])))
    |> Enum.map(&(String.split(&1["path"], "/", parts: 2) |> hd()))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [".git", "node_modules", "vendor", "deps", "_build"]))
    |> Enum.sort()
    |> Enum.take(20)
  end

  defp languages(tree) do
    extensions = %{
      ".ex" => "Elixir",
      ".exs" => "Elixir",
      ".go" => "Go",
      ".js" => "JavaScript",
      ".ts" => "TypeScript",
      ".tsx" => "TypeScript",
      ".py" => "Python",
      ".rb" => "Ruby",
      ".rs" => "Rust",
      ".java" => "Java",
      ".kt" => "Kotlin",
      ".sh" => "Shell"
    }

    tree
    |> Enum.filter(&(&1["type"] == "blob" and is_binary(&1["path"])))
    |> Enum.reduce(%{}, fn entry, counts ->
      case Map.get(extensions, Path.extname(entry["path"])) do
        nil -> counts
        language -> Map.update(counts, language, 1, &(&1 + 1))
      end
    end)
    |> Enum.sort_by(fn {language, count} -> {-count, language} end)
  end

  defp commands(sources) do
    []
    |> add_if(Map.has_key?(sources, "mix.exs"), ["mix deps.get", "mix test"])
    |> add_if(Map.has_key?(sources, "package.json"), ["npm install", "npm test"])
    |> add_if(Map.has_key?(sources, "go.mod"), ["go test ./..."])
    |> add_if(Map.has_key?(sources, "Cargo.toml"), ["cargo test"])
    |> add_if(Map.has_key?(sources, "pyproject.toml"), ["python -m pytest"])
    |> add_if(Map.has_key?(sources, "Gemfile"), ["bundle install", "bundle exec rake test"])
    |> add_if(Map.has_key?(sources, "Makefile"), ["make test"])
    |> Enum.uniq()
  end

  defp add_if(items, true, additions), do: items ++ additions
  defp add_if(items, false, _additions), do: items

  defp ci_summary(tree, source_url) do
    if Enum.any?(
         tree,
         &(is_binary(&1["path"]) and String.starts_with?(&1["path"], ".github/workflows/"))
       ) do
      "GitHub Actions workflows are under [`.github/workflows/`](#{source_url}/.github/workflows). Read the exact workflow before changing release or deployment behavior."
    else
      "No GitHub Actions workflow was present at the scanned revision. Confirm CI and release ownership elsewhere."
    end
  end

  defp guidance(sources, source_url) do
    ["AGENTS.md", "CONTRIBUTING.md"]
    |> Enum.filter(&Map.has_key?(sources, &1))
    |> case do
      [] ->
        "No AGENTS.md or CONTRIBUTING.md was found. Follow the existing code and ask before inventing repository-wide conventions."

      paths ->
        "Read " <>
          Enum.map_join(paths, " and ", &"[`#{&1}`](#{source_url}/#{&1})") <>
          " before making changes. These files remain authoritative over this summary."
    end
  end

  defp bullets([], _render, empty), do: empty
  defp bullets(items, render, _empty), do: Enum.map_join(items, "\n", &("- " <> render.(&1)))

  defp owner(repository) do
    case String.split(repository, "/", parts: 2) do
      [owner, _name] when owner != "" -> {:ok, owner}
      _invalid -> {:error, {:github_onboarding, :repository}}
    end
  end

  defp commit(value) when is_binary(value) do
    value = String.downcase(value)

    if Regex.match?(~r/\A[0-9a-f]{40}\z/, value),
      do: {:ok, value},
      else: {:error, {:github_onboarding, :commit}}
  end

  defp client(binding_name) do
    settings = Ryker.Settings.fetch!()
    defaults = Ryker.Defaults.fetch!(:github)

    JSONClient.new(%{
      base_url: settings.github.api_url,
      finch: Ryker.CoopFinch,
      receive_timeout: defaults.receive_timeout_ms,
      token_provider: fn -> InstallationTokens.token(binding_name, :onboarding) end
    })
  end

  defp request(client, method, path, body \\ nil),
    do: JSONClient.request(client, method, path, body, @headers)

  defp encode_ref(ref), do: URI.encode(ref, &URI.char_unreserved?/1)
end
