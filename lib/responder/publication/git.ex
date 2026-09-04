defmodule Responder.Publication.Git do
  @moduledoc """
  Reconstructs and pushes the exact Coop-reviewed candidate in isolation.

  The checkout starts from the reviewed parent commit, applies the verified
  complete patch, and refuses publication unless Git writes the exact reviewed
  candidate tree. A force-with-lease protects both new and existing branches.
  """

  @behaviour Responder.Publication.GitAPI

  alias Responder.Publication.Request

  @git_identity ~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @credential_patterns [
    ~r/(?i)\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
    ~r/\bxapp-[A-Za-z0-9-]{10,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[A-Z0-9]{16}\b/,
    ~r/\bemk-[A-Za-z0-9_-]{10,}\b/,
    ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  ]

  @impl true
  def publish_candidate(%Request{} = request, repository, binding)
      when is_map(repository) and is_map(binding) do
    with {:ok, settings} <- settings(repository, binding),
         :ok <- safe_patch(request.patch, settings.secrets),
         {:ok, branch} <- branch(request, settings.branch_prefix),
         {:ok, token} <- token(settings.token_provider),
         {:ok, work} <- create_work_directory(settings.state_dir) do
      try do
        build_and_push(request, settings, branch, token, work)
      after
        File.rm_rf(work)
      end
    end
  end

  def publish_candidate(_request, _repository, _binding),
    do: {:error, {:invalid_publication_git, :request}}

  defp build_and_push(request, settings, branch, token, work) do
    patch_path = Path.join(work, "review.patch")

    with :ok <- File.write(patch_path, request.patch, [:binary, :exclusive]),
         :ok <- File.chmod(patch_path, 0o600),
         {:ok, _output} <- run(settings, work, ["init", "--quiet"]),
         {:ok, _output} <- run(settings, work, ["remote", "add", "source", settings.path]),
         {:ok, _output} <-
           run(settings, work, [
             "fetch",
             "--quiet",
             "--no-tags",
             "source",
             request.review["parent_head"]
           ]),
         {:ok, _output} <-
           run(settings, work, [
             "checkout",
             "--quiet",
             "--detach",
             request.review["parent_head"]
           ]),
         {:ok, _output} <-
           run(settings, work, [
             "apply",
             "--index",
             "--binary",
             "--whitespace=error-all",
             patch_path
           ]),
         {:ok, tree} <- run(settings, work, ["write-tree"]),
         :ok <- exact_tree(tree, request.review["candidate_tree"]),
         {:ok, _output} <- commit(request, settings, work),
         {:ok, commit_sha} <- full_identity(settings, work, ["rev-parse", "HEAD"]),
         {:ok, remote_sha} <- remote_ref(settings, work, token, branch),
         :ok <- expected_remote(remote_sha, request, commit_sha, branch),
         :ok <- push_if_needed(settings, work, token, branch, remote_sha, commit_sha) do
      {:ok, %{branch_ref: "refs/heads/#{branch}", commit_sha: commit_sha}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit(request, settings, work) do
    date = DateTime.to_iso8601(request.approved_at)

    env = [
      GIT_AUTHOR_NAME: settings.commit_name,
      GIT_AUTHOR_EMAIL: settings.commit_email,
      GIT_COMMITTER_NAME: settings.commit_name,
      GIT_COMMITTER_EMAIL: settings.commit_email,
      GIT_AUTHOR_DATE: date,
      GIT_COMMITTER_DATE: date
    ]

    message =
      safe_title(request.title) <>
        "\n\nPrepared by Emisar Responder from Coop review #{request.review["operation_id"]}."

    run(settings, work, ["commit", "--quiet", "-m", message], env: env)
  end

  defp remote_ref(settings, work, token, branch) do
    case run(
           settings,
           work,
           ["ls-remote", "--heads", settings.remote_url, "refs/heads/#{branch}"],
           env: auth_env(token)
         ) do
      {:ok, output} -> parse_remote_ref(output, branch)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_remote_ref(output, branch) do
    case String.split(output) do
      [] ->
        {:ok, nil}

      [sha, ref] when is_binary(sha) ->
        if ref == "refs/heads/#{branch}" and Regex.match?(@git_identity, sha),
          do: {:ok, sha},
          else: {:error, {:publication_git_protocol_error, :remote_ref}}

      _invalid ->
        {:error, {:publication_git_protocol_error, :remote_ref}}
    end
  end

  defp expected_remote(commit_sha, _request, commit_sha, _branch), do: :ok

  defp expected_remote(
         remote_sha,
         %Request{existing_pull_request: %{"head_commit" => remote_sha}},
         _commit_sha,
         _branch
       ),
       do: :ok

  defp expected_remote(
         nil,
         %Request{existing_pull_request: nil, review: %{"pull_request" => nil}},
         _commit_sha,
         _branch
       ),
       do: :ok

  defp expected_remote(
         remote_sha,
         %Request{
           existing_pull_request: nil,
           review: %{"pull_request" => %{"head_commit" => remote_sha}}
         },
         _commit_sha,
         _branch
       ),
       do: :ok

  defp expected_remote(
         remote_sha,
         %Request{existing_pull_request: nil, review: %{"pull_request" => nil}},
         commit_sha,
         branch
       ),
       do:
         git_conflict(
           :publication_branch_already_exists,
           remote_sha,
           commit_sha,
           branch
         )

  defp expected_remote(remote_sha, %Request{}, commit_sha, branch),
    do: git_conflict(:publication_branch_changed, remote_sha, commit_sha, branch)

  defp git_conflict(code, observed_head, candidate_commit, branch)
       when is_binary(observed_head) do
    {:error,
     {:publication_git_conflict, code,
      %{
        "branch_ref" => "refs/heads/#{branch}",
        "candidate_commit_sha" => candidate_commit,
        "observed_head_sha" => observed_head
      }}}
  end

  defp git_conflict(code, _observed_head, _candidate_commit, _branch), do: {:error, code}

  defp push_if_needed(_settings, _work, _token, _branch, commit_sha, commit_sha), do: :ok

  defp push_if_needed(settings, work, token, branch, remote_sha, commit_sha) do
    expected = remote_sha || ""

    case run(
           settings,
           work,
           [
             "push",
             "--quiet",
             "--force-with-lease=refs/heads/#{branch}:#{expected}",
             settings.remote_url,
             "#{commit_sha}:refs/heads/#{branch}"
           ],
           env: auth_env(token)
         ) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp full_identity(settings, work, arguments) do
    case run(settings, work, arguments) do
      {:ok, output} ->
        value = String.trim(output)

        if Regex.match?(@git_identity, value),
          do: {:ok, value},
          else: {:error, {:publication_git_protocol_error, :git_identity}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_tree(output, expected) do
    if String.trim(output) == expected,
      do: :ok,
      else: {:error, :publication_candidate_tree_mismatch}
  end

  defp branch(%Request{existing_pull_request: %{"ref" => ref}}, prefix),
    do: owned_branch(ref, prefix)

  defp branch(%Request{review: %{"pull_request" => %{"ref" => ref}}}, prefix),
    do: owned_branch(ref, prefix)

  defp branch(request, prefix) do
    slug =
      request.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 42)
      |> String.trim_trailing("-")

    slug = if slug == "", do: "change", else: slug
    suffix = request.publication_ref |> String.split(":") |> List.last() |> String.slice(-10, 10)
    safe_branch("#{prefix}/#{slug}-#{suffix}")
  end

  defp safe_branch("refs/heads/" <> branch), do: safe_branch(branch)

  defp safe_branch(branch) do
    invalid =
      not is_binary(branch) or byte_size(branch) not in 1..240 or
        String.starts_with?(branch, ["-", "/"]) or String.ends_with?(branch, ["/", "."]) or
        String.contains?(branch, [
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

    if invalid, do: {:error, :publication_branch_invalid}, else: {:ok, branch}
  end

  defp owned_branch(ref, prefix) do
    with {:ok, branch} <- safe_branch(ref),
         {:ok, prefix} <- safe_branch(prefix),
         true <- String.starts_with?(branch, prefix <> "/") do
      {:ok, branch}
    else
      false -> {:error, :publication_branch_not_owned}
      {:error, _reason} = error -> error
    end
  end

  defp run(settings, work, arguments, options \\ []),
    do: settings.command.run(work, arguments, options)

  defp auth_env(token) do
    encoded = Base.encode64("x-access-token:#{token}")

    [
      GIT_CONFIG_COUNT: "1",
      GIT_CONFIG_KEY_0: "http.https://github.com/.extraheader",
      GIT_CONFIG_VALUE_0: "AUTHORIZATION: basic #{encoded}",
      GIT_TERMINAL_PROMPT: "0"
    ]
  end

  defp settings(repository, binding) do
    with %{base_branch: base, github_repository: github, path: path} <- repository,
         {:ok, _base} <- safe_branch(base),
         true <- is_binary(github) and Regex.match?(@repository, github),
         true <- is_binary(path) and Path.type(path) == :absolute and File.dir?(path),
         %{
           branch_prefix: prefix,
           command: command,
           commit_email: email,
           commit_name: name,
           secrets: secrets,
           state_dir: state_dir,
           token_provider: provider
         } <- binding,
         {:ok, _prefix} <- safe_branch(prefix),
         true <- module_callback?(command, :run, 3),
         true <- is_function(provider, 0),
         true <- is_list(secrets) and Enum.all?(secrets, &is_binary/1),
         true <- text?(name, 256) and email?(email),
         true <- is_binary(state_dir) and Path.type(state_dir) == :absolute,
         :ok <- File.mkdir_p(state_dir) do
      {:ok,
       %{
         base_branch: base,
         branch_prefix: prefix,
         command: command,
         commit_email: email,
         commit_name: name,
         path: path,
         remote_url: "https://github.com/#{github}.git",
         secrets: secrets,
         state_dir: state_dir,
         token_provider: provider
       }}
    else
      false -> {:error, {:invalid_publication_git, :binding}}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_publication_git, :binding}}
    end
  end

  defp create_work_directory(state_dir) do
    path = Path.join(state_dir, "publication-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    end
  end

  defp token(provider) do
    case provider.() do
      {:ok, token} when is_binary(token) and byte_size(token) in 1..4_096 -> {:ok, token}
      {:error, reason} -> {:error, {:publication_credentials_unavailable, reason}}
      _invalid -> {:error, {:publication_credentials_unavailable, :invalid_token}}
    end
  rescue
    error -> {:error, {:publication_credentials_unavailable, Exception.message(error)}}
  end

  defp safe_patch(patch, secrets) do
    contains_secret =
      Enum.any?(secrets, &(byte_size(&1) >= 8 and :binary.match(patch, &1) != :nomatch))

    shaped_secret = Enum.any?(@credential_patterns, &Regex.match?(&1, patch))

    if contains_secret or shaped_secret,
      do: {:error, :publication_patch_contains_secret},
      else: :ok
  end

  defp safe_title(value) do
    value
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.replace("@", "@ ")
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, 200)
    |> case do
      "" -> "Responder engineering task"
      title -> title
    end
  end

  defp module_callback?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  defp text?(value, maximum),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
        String.trim(value) != ""

  defp email?(value),
    do: text?(value, 320) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/, value)
end
