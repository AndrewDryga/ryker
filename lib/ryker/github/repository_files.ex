defmodule Ryker.GitHub.RepositoryFiles do
  @moduledoc """
  A repository's files and its knowledge pull request, through the GitHub
  App: the default branch head setup pins (`Ryker.GitHub.Onboarding`), and
  everything the knowledge lane reads and proposes
  (`Ryker.RepositoryKnowledge.Remote`).

  RYKER.md is proposed on one stable branch, `ryker/repository-knowledge`, as a
  draft pull request Ryker never merges. While it is open Ryker updates it
  there; once it is merged or closed the branch starts again from the
  default branch head. An archived repository refuses every write, which is
  checked before one is tried and read from GitHub's refusal after.
  """

  @behaviour Ryker.GitHub.Onboarding
  @behaviour Ryker.RepositoryKnowledge.Remote

  alias Ryker.Delivery.JSONClient
  alias Ryker.GitHub.InstallationTokens
  alias Ryker.RepositoryKnowledge.Document

  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "ryker"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @branch "ryker/repository-knowledge"
  @path "RYKER.md"
  @maximum_tree_entries 10_000
  @maximum_source_bytes 128_000
  # GitHub lists at most this many files of a comparison.
  @maximum_compared_files 300

  @doc "The branch Ryker proposes RYKER.md on."
  @spec branch() :: String.t()
  def branch, do: @branch

  # -- Reading ---------------------------------------------------------------------

  @impl Ryker.GitHub.Onboarding
  def pin(binding, repository), do: head(binding, repository)

  @impl Ryker.RepositoryKnowledge.Remote
  def head(binding, repository) do
    with {:ok, client} <- client(binding.name),
         do: head_commit(client, repository)
  end

  defp head_commit(client, repository) do
    path =
      "/repos/#{repository.github_repository}/git/ref/heads/#{encode_ref(repository.base_branch)}"

    case request(client, :get, path) do
      {:ok, %{status: 200, body: %{"object" => %{"sha" => sha}}}} when is_binary(sha) ->
        commit(sha)

      {:ok, %{status: 404}} ->
        {:error, {:github_onboarding, :not_found}}

      {:ok, %{status: 409}} ->
        {:error, :repository_empty}

      {:ok, %{status: status} = response} when status in [401, 403] ->
        refused(response)

      {:ok, _other} ->
        {:error, {:github_onboarding, :response}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def repository(binding, repository) do
    with {:ok, client} <- client(binding.name) do
      case request(client, :get, "/repos/#{repository.github_repository}") do
        {:ok, %{status: 200, body: %{} = body}} -> {:ok, %{archived: body["archived"] == true}}
        {:ok, %{status: 404}} -> {:error, {:github_onboarding, :not_found}}
        {:ok, %{status: status} = response} when status in [401, 403] -> refused(response)
        {:ok, _other} -> {:error, {:github_onboarding, :response}}
        {:error, _reason} = error -> error
      end
    end
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def tree(binding, repository, commit) do
    path = "/repos/#{repository.github_repository}/git/trees/#{commit}?recursive=1"

    with {:ok, client} <- client(binding.name),
         do: client |> request(:get, path) |> tree_entries()
  end

  defp tree_entries({:ok, %{status: 200, body: %{"tree" => entries} = body}})
       when is_list(entries) do
    if body["truncated"] == true or length(entries) > @maximum_tree_entries,
      do: {:error, :repository_too_large},
      else: {:ok, entries}
  end

  defp tree_entries({:ok, %{status: status} = response}) when status in [401, 403],
    do: refused(response)

  defp tree_entries({:ok, %{status: 404}}), do: {:error, {:github_onboarding, :not_found}}
  defp tree_entries({:ok, _other}), do: {:error, {:github_onboarding, :tree}}

  defp tree_entries({:error, {:delivery_protocol_error, :response_too_large}}),
    do: {:error, :repository_too_large}

  defp tree_entries({:error, _reason} = error), do: error

  @impl Ryker.RepositoryKnowledge.Remote
  def read(binding, repository, path, ref) do
    with {:ok, client} <- client(binding.name),
         {:ok, file} <- file(client, repository.github_repository, path, ref) do
      case file do
        :not_found -> {:ok, :not_found}
        %{text: text} -> {:ok, text}
      end
    end
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def changes(binding, repository, base, head) do
    path = "/repos/#{repository.github_repository}/compare/#{base}...#{head}"

    with {:ok, client} <- client(binding.name),
         do: client |> request(:get, path) |> compared()
  end

  defp compared({:ok, %{status: 200, body: %{"files" => files}}}) when is_list(files) do
    if length(files) >= @maximum_compared_files,
      do: {:ok, :unknown},
      else: {:ok, Enum.flat_map(files, &changed_paths/1)}
  end

  defp compared({:ok, %{status: 200, body: %{}}}), do: {:ok, []}

  # The written commit is gone, after a force push.
  defp compared({:ok, %{status: status}}) when status in [404, 422], do: {:ok, :unknown}

  defp compared({:ok, %{status: status} = response}) when status in [401, 403],
    do: refused(response)

  defp compared({:ok, _other}), do: {:error, {:github_onboarding, :response}}

  defp compared({:error, {:delivery_protocol_error, :response_too_large}}),
    do: {:ok, :unknown}

  defp compared({:error, _reason} = error), do: error

  defp changed_paths(%{"filename" => name} = file) when is_binary(name) do
    case file["previous_filename"] do
      previous when is_binary(previous) -> [name, previous]
      _none -> [name]
    end
  end

  defp changed_paths(_file), do: []

  @impl Ryker.RepositoryKnowledge.Remote
  def pull_request(binding, repository, number) when is_integer(number) and number > 0 do
    with {:ok, client} <- client(binding.name) do
      case request(client, :get, "/repos/#{repository.github_repository}/pulls/#{number}") do
        {:ok, %{status: 200, body: %{"state" => "open"}}} -> {:ok, :open}
        {:ok, %{status: 200, body: %{"merged" => true}}} -> {:ok, :merged}
        {:ok, %{status: 200, body: %{"state" => "closed"}}} -> {:ok, :closed}
        {:ok, %{status: 404}} -> {:ok, :closed}
        {:ok, %{status: status} = response} when status in [401, 403] -> refused(response)
        {:ok, _other} -> {:error, {:github_onboarding, :response}}
        {:error, _reason} = error -> error
      end
    end
  end

  # -- Proposing RYKER.md ----------------------------------------------------------

  @impl Ryker.RepositoryKnowledge.Remote
  def publish(binding, repository, %{document: document, body: body}) do
    slug = repository.github_repository

    with {:ok, client} <- client(binding.name),
         :ok <- writable(client, slug),
         {:ok, owner} <- owner(slug),
         {:ok, head} <- head_commit(client, repository),
         {:ok, base} <- file(client, slug, @path, head),
         {:ok, open} <- open_pull(client, slug, owner) do
      base_document = text(base)

      with {:ok, outcome} <-
             propose(open, client, repository, owner, head, base, document, body),
           do: {:ok, Map.merge(outcome, %{base_commit: head, base_document: base_document})}
    end
  end

  defp propose(
         %{"html_url" => url, "number" => number},
         client,
         repository,
         _owner,
         _head,
         _base,
         document,
         body
       )
       when is_binary(url) and is_integer(number) do
    with :ok <- update_open(client, repository.github_repository, number, document, body),
         do: {:ok, %{outcome: :updated, url: url, number: number}}
  end

  defp propose(:not_found, client, repository, owner, head, base, document, body) do
    if Document.same?(text(base), document) do
      {:ok, %{outcome: :unchanged, url: nil, number: nil}}
    else
      with {:ok, pull} <- open_new(client, repository, owner, head, base, document, body),
           do: {:ok, Map.put(pull, :outcome, :opened)}
    end
  end

  # The open pull request holds Ryker's last proposal: the new one replaces
  # its file, and its description says why. A branch that already says the
  # same is left alone rather than given a commit that only moves the date.
  defp update_open(client, slug, number, document, body) do
    with {:ok, current} <- file(client, slug, @path, @branch) do
      if Document.same?(text(current), document),
        do: :ok,
        else: replace_proposal(client, slug, number, current, document, body)
    end
  end

  defp replace_proposal(client, slug, number, current, document, body) do
    with :ok <- write_file(client, slug, current, document, "Update Ryker repository knowledge") do
      case request(client, :patch, "/repos/#{slug}/pulls/#{number}", %{"body" => body}) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: status} = response} when status in [401, 403] -> refused(response)
        {:ok, _other} -> {:error, {:github_onboarding, :pull_request}}
        {:error, _reason} = error -> error
      end
    end
  end

  # No proposal is open: the branch starts again at the default branch head,
  # whatever an earlier, finished proposal left on it, so the pull request
  # shows exactly this document.
  defp open_new(client, repository, owner, head, base, document, body) do
    slug = repository.github_repository
    title = if base == :not_found, do: "Add", else: "Update"

    message = "#{title} Ryker repository knowledge"

    with :ok <- reset_branch(client, slug, head),
         :ok <- write_file(client, slug, base, document, message),
         do: create_pull(client, repository, owner, message, body, true)
  end

  defp reset_branch(client, slug, head) do
    ref = "heads/#{encode_ref(@branch)}"

    case request(client, :get, "/repos/#{slug}/git/ref/#{ref}") do
      {:ok, %{status: 200}} ->
        client
        |> request(:patch, "/repos/#{slug}/git/refs/#{ref}", %{"sha" => head, "force" => true})
        |> branch_written()

      {:ok, %{status: 404}} ->
        client
        |> request(:post, "/repos/#{slug}/git/refs", %{
          "ref" => "refs/heads/#{@branch}",
          "sha" => head
        })
        |> branch_written()

      {:ok, %{status: status} = response} when status in [401, 403] ->
        refused(response)

      {:ok, _other} ->
        {:error, {:github_onboarding, :branch}}

      {:error, _reason} = error ->
        error
    end
  end

  defp branch_written({:ok, %{status: status}}) when status in [200, 201], do: :ok

  defp branch_written({:ok, %{status: status} = response}) when status in [401, 403],
    do: refused(response)

  defp branch_written({:ok, _other}), do: {:error, {:github_onboarding, :branch}}
  defp branch_written({:error, _reason} = error), do: error

  # `current` is the file the branch holds now, whose blob a replacement names.
  defp write_file(client, slug, current, document, message) do
    body =
      %{"branch" => @branch, "content" => Base.encode64(document), "message" => message}
      |> then(fn body ->
        case current do
          %{sha: sha} when is_binary(sha) -> Map.put(body, "sha", sha)
          _new -> body
        end
      end)

    case request(client, :put, "/repos/#{slug}/contents/#{@path}", body) do
      {:ok, %{status: status}} when status in [200, 201] -> :ok
      {:ok, %{status: status} = response} when status in [401, 403] -> refused(response)
      {:ok, _other} -> {:error, {:github_onboarding, :write}}
      {:error, _reason} = error -> error
    end
  end

  # A repository that cannot have draft pull requests (a private one on a
  # free plan) gets an ordinary one; Ryker still never merges it.
  defp create_pull(client, repository, owner, title, body, draft?) do
    slug = repository.github_repository

    request =
      request(client, :post, "/repos/#{slug}/pulls", %{
        "base" => repository.base_branch,
        "body" => body,
        "draft" => draft?,
        "head" => @branch,
        "title" => title
      })

    case request do
      {:ok, %{status: 201, body: %{"html_url" => url, "number" => number}}}
      when is_binary(url) and is_integer(number) ->
        {:ok, %{url: url, number: number}}

      {:ok, %{status: 422, body: refusal}} when draft? ->
        if drafts_refused?(refusal),
          do: create_pull(client, repository, owner, title, body, false),
          else: reconcile_pull(client, slug, owner)

      {:ok, %{status: status} = response} when status in [401, 403] ->
        refused(response)

      {:ok, _other} ->
        reconcile_pull(client, slug, owner)

      {:error, _reason} = error ->
        error
    end
  end

  # GitHub names drafts in its message, or in one of its validation errors
  # under "Validation Failed".
  defp drafts_refused?(%{} = refusal) do
    errors = if is_list(refusal["errors"]), do: refusal["errors"], else: []

    [refusal["message"] | Enum.map(errors, &(is_map(&1) && &1["message"]))]
    |> Enum.any?(&(is_binary(&1) and &1 =~ ~r/draft/i))
  end

  defp drafts_refused?(_refusal), do: false

  defp reconcile_pull(client, slug, owner) do
    case open_pull(client, slug, owner) do
      {:ok, %{"html_url" => url, "number" => number}} -> {:ok, %{url: url, number: number}}
      _other -> {:error, {:github_onboarding, :pull_request}}
    end
  end

  defp open_pull(client, slug, owner) do
    query =
      URI.encode_query(%{"head" => "#{owner}:#{@branch}", "per_page" => 1, "state" => "open"})

    case request(client, :get, "/repos/#{slug}/pulls?#{query}") do
      {:ok, %{status: 200, body: [pull | _]}} -> {:ok, pull}
      {:ok, %{status: 200, body: []}} -> {:ok, :not_found}
      {:ok, %{status: status} = response} when status in [401, 403] -> refused(response)
      {:ok, _other} -> {:error, {:github_onboarding, :pull_request}}
      {:error, _reason} = error -> error
    end
  end

  # An archived repository refuses every write, and GitHub's refusal of the
  # branch does not always say why, so the repository's own flag does.
  defp writable(client, slug) do
    case request(client, :get, "/repos/#{slug}") do
      {:ok, %{status: 200, body: %{"archived" => true}}} ->
        {:error, {:github_onboarding, :archived}}

      _writable_or_unknown ->
        :ok
    end
  end

  # GitHub refuses every write to an archived repository with 403 "Repository
  # was archived so is read-only", which read as a missing App permission
  # (AndrewDryga/andrewdryga.github.com, 2026-09-27).
  defp refused(%{body: %{"message" => message}}) when is_binary(message) do
    if message =~ ~r/archived/i,
      do: {:error, {:github_onboarding, :archived}},
      else: {:error, {:github_onboarding, :permission}}
  end

  defp refused(_response), do: {:error, {:github_onboarding, :permission}}

  # -- Files -----------------------------------------------------------------------

  defp text(%{text: text}), do: text
  defp text(:not_found), do: nil

  defp file(client, slug, path, ref) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))

    query = URI.encode_query(%{"ref" => ref})

    case request(client, :get, "/repos/#{slug}/contents/#{encoded}?#{query}") do
      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64"} = body}}
      when is_binary(content) ->
        decode_file(content, body["sha"])

      {:ok, %{status: status} = response} when status in [401, 403] ->
        refused(response)

      {:ok, _unavailable} ->
        {:error, :source_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_file(content, sha) do
    with {:ok, decoded} <- Base.decode64(String.replace(content, "\n", "")),
         true <- byte_size(decoded) <= @maximum_source_bytes and String.valid?(decoded) do
      {:ok, %{text: decoded, sha: sha}}
    else
      _too_large_or_invalid -> {:error, :source_unavailable}
    end
  end

  # -- Plumbing --------------------------------------------------------------------

  defp owner(slug) do
    case String.split(slug, "/", parts: 2) do
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
    do: requester().request(client, method, path, body, @headers)

  # GitHub itself; in tests, the replies each test records (config/test.exs).
  defp requester, do: Application.get_env(:ryker, :github_files_requester, JSONClient)

  defp encode_ref(ref), do: URI.encode(ref, &URI.char_unreserved?/1)
end
