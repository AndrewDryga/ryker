defmodule Responder.Publication.GitHubPublisher do
  @moduledoc """
  Publishes one operator-approved reviewed candidate as a GitHub draft PR.

  Git reconstruction/push and GitHub PR creation are separately reconciled.
  Every response is checked against the trusted repository, exact branch, exact
  commit, and existing-PR binding before a publication receipt is returned.
  """

  @behaviour Responder.Publication.Publisher

  alias Responder.Publication.Request

  @impl true
  def publish(%Request{} = request, binding) when is_map(binding) do
    with {:ok, settings, repository} <- settings(binding, request.repository),
         :ok <- verify_existing_before_publish(request, settings, repository),
         {:ok, git} <- settings.git.publish_candidate(request, repository, settings.git_binding),
         {:ok, branch} <- branch(git.branch_ref),
         {:ok, pull} <- ensure_pull_request(request, settings, repository, branch, git.commit_sha),
         :ok <- exact_pull_request(request, repository, branch, git.commit_sha, pull) do
      {:ok,
       %{
         "branch_ref" => git.branch_ref,
         "candidate_tree" => request.review["candidate_tree"],
         "commit_sha" => git.commit_sha,
         "pull_request_number" => pull["number"],
         "pull_request_url" => pull["url"],
         "repository" => request.repository
       }}
    end
  end

  def publish(_request, _binding),
    do: {:error, {:invalid_publication_publisher, :request}}

  @doc false
  @spec get_publication_status(map(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def get_publication_status(binding, github_repository, pull_request_number)
      when is_map(binding) and is_binary(github_repository) and is_integer(pull_request_number) and
             pull_request_number > 0 do
    with {:ok, settings} <- status_settings(binding, github_repository) do
      settings.api.get_publication_status(
        settings.client,
        github_repository,
        pull_request_number
      )
    end
  end

  def get_publication_status(_binding, _github_repository, _pull_request_number),
    do: {:error, :publication_repository_not_configured}

  defp verify_existing_before_publish(
         %Request{review: %{"pull_request" => nil}},
         _settings,
         _repo
       ),
       do: :ok

  defp verify_existing_before_publish(
         %Request{review: %{"pull_request" => pull_request}} = request,
         settings,
         repository
       )
       when is_map(pull_request) do
    with {:ok, current} <-
           settings.api.get_pull_request(
             settings.client,
             repository.github_repository,
             pull_request["number"]
           ),
         {:ok, branch} <- branch(pull_request["ref"]),
         :ok <-
           exact_existing_pull(
             current,
             pull_request["number"],
             branch,
             pull_request["head_commit"],
             repository.base_branch
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_publication_publisher, request.publication_ref}}
    end
  end

  defp ensure_pull_request(
         %Request{review: %{"pull_request" => pull_request}},
         settings,
         repository,
         _branch,
         _commit_sha
       )
       when is_map(pull_request) do
    settings.api.get_pull_request(
      settings.client,
      repository.github_repository,
      pull_request["number"]
    )
  end

  defp ensure_pull_request(request, settings, repository, branch, commit_sha) do
    case settings.api.find_open_pull_request(
           settings.client,
           repository.github_repository,
           repository.owner,
           branch
         ) do
      {:ok, pull} ->
        {:ok, pull}

      :not_found ->
        settings.api.create_draft_pull_request(
          settings.client,
          repository.github_repository,
          safe_title(request.title),
          pull_request_body(request, commit_sha),
          branch,
          repository.base_branch
        )

      {:error, reason} ->
        {:error, {:publication_github_reconciliation_failed, reason}}
    end
  end

  defp exact_pull_request(request, repository, branch, commit_sha, pull) do
    pull_request = request.review["pull_request"]

    checks = [
      pull["state"] == "open",
      not pull["merged"],
      pull["head_ref"] == branch,
      pull["head_sha"] == commit_sha,
      pull["base_ref"] == repository.base_branch,
      is_nil(pull_request) or pull["number"] == pull_request["number"],
      is_map(pull_request) or pull["draft"] == true
    ]

    if Enum.all?(checks),
      do: :ok,
      else: {:error, :publication_pull_request_mismatch}
  end

  defp exact_existing_pull(pull, number, branch, sha, base_branch) do
    if pull["number"] == number and pull["state"] == "open" and not pull["merged"] and
         pull["head_ref"] == branch and pull["head_sha"] == sha and
         pull["base_ref"] == base_branch,
       do: :ok,
       else: {:error, :publication_existing_pull_request_changed}
  end

  defp pull_request_body(request, commit_sha) do
    """
    ## Responder task

    #{safe_body(request.body)}

    ## Publication proof

    - Coop session: `#{request.review["session_id"]}`
    - Reviewed parent: `#{request.review["parent_head"]}`
    - Reviewed tree: `#{request.review["candidate_tree"]}`
    - Publication commit: `#{commit_sha}`
    - Gate: `#{request.review["gate"]}`
    - Rebase: `#{request.review["rebase"]}`
    """
    |> String.trim()
  end

  defp safe_title(value) do
    value
    |> safe_text()
    |> String.slice(0, 200)
    |> case do
      "" -> "Responder engineering task"
      title -> title
    end
  end

  defp safe_body(value), do: value |> safe_text() |> String.slice(0, 8_000)

  defp safe_text(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.replace("@", "@\u200B")
    |> String.split()
    |> Enum.join(" ")
  end

  defp branch("refs/heads/" <> branch), do: branch(branch)

  defp branch(value) do
    invalid =
      not is_binary(value) or byte_size(value) not in 1..240 or
        String.starts_with?(value, ["-", "/"]) or String.ends_with?(value, ["/", "."]) or
        String.contains?(value, [
          "..",
          "@{",
          " ",
          "~",
          "^",
          ":",
          "?",
          "*",
          "[",
          "\\",
          "\r",
          "\n",
          "\t"
        ])

    if invalid,
      do: {:error, :publication_branch_invalid},
      else: {:ok, value}
  end

  defp settings(binding, repository_alias) do
    with %{
           git: git,
           repositories: repositories
         } <- binding,
         {:ok,
          %{
            api: api,
            client: client,
            git_binding: git_binding,
            base_branch: base_branch,
            github_repository: github_repository
          } = repository} <- Map.fetch(repositories, repository_alias),
         [owner, _name] <- String.split(github_repository || "", "/", parts: 2),
         true <- module_callback?(api, :find_open_pull_request, 4),
         true <- module_callback?(api, :create_draft_pull_request, 6),
         true <- module_callback?(api, :get_pull_request, 3),
         true <- module_callback?(git, :publish_candidate, 3),
         {:ok, _branch} <- branch(base_branch) do
      {:ok, %{api: api, client: client, git: git, git_binding: git_binding},
       Map.merge(repository, %{owner: owner})}
    else
      _invalid -> {:error, {:publication_repository_not_configured, repository_alias}}
    end
  end

  defp status_settings(%{repositories: repositories}, github_repository)
       when is_map(repositories) do
    matches =
      repositories
      |> Map.values()
      |> Enum.filter(fn
        %{github_repository: ^github_repository} -> true
        _invalid -> false
      end)
      |> Enum.map(fn
        %{api: api, client: client} -> %{api: api, client: client}
        _invalid -> :invalid
      end)
      |> Enum.uniq()

    case matches do
      [%{api: api} = settings] ->
        if module_callback?(api, :get_publication_status, 3),
          do: {:ok, settings},
          else: {:error, {:publication_repository_not_configured, github_repository}}

      _none_or_ambiguous ->
        {:error, {:publication_repository_not_configured, github_repository}}
    end
  end

  defp status_settings(_binding, github_repository),
    do: {:error, {:publication_repository_not_configured, github_repository}}

  defp module_callback?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)
end
