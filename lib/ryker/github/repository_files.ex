defmodule Ryker.GitHub.RepositoryFiles do
  @moduledoc """
  A repository's files, through the GitHub App: the default branch head
  setup pins (`Ryker.GitHub.Onboarding`), and everything the knowledge lane
  reads (`Ryker.RepositoryKnowledge.Remote`). It only reads: RYKER.md is
  Ryker's own, and nothing is written to the repository.
  """

  @behaviour Ryker.GitHub.Onboarding
  @behaviour Ryker.RepositoryKnowledge.Remote

  alias Ryker.Delivery.JSONClient
  alias Ryker.GitHub.Client.Transport
  alias Ryker.GitHub.InstallationTokens

  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "ryker"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @maximum_tree_entries 10_000
  # GitHub sends a file's content inline up to 1 MB, and Ryker reads all of
  # it: a smaller bound dropped real commands from a 135,820-byte README
  # (2026-09-27). A run reads at most 40 cited files.
  @maximum_source_bytes 1_048_576
  # Statuses GitHub turns a request away with (`refused/1`).
  @refused [401, 403, 429]
  # GitHub lists at most this many files of a comparison.
  @maximum_compared_files 300

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

    case get(client, path) do
      {:ok, %{status: 200, body: %{"object" => %{"sha" => sha}}}} when is_binary(sha) ->
        commit(sha)

      {:ok, %{status: 404}} ->
        {:error, {:github_onboarding, :not_found}}

      {:ok, %{status: 409}} ->
        {:error, :repository_empty}

      {:ok, %{status: status} = response} when status in @refused ->
        refused(response)

      {:ok, _other} ->
        {:error, {:github_onboarding, :response}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def tree(binding, repository, commit) do
    path = "/repos/#{repository.github_repository}/git/trees/#{commit}?recursive=1"

    with {:ok, client} <- client(binding.name),
         do: client |> get(path) |> tree_entries()
  end

  defp tree_entries({:ok, %{status: 200, body: %{"tree" => entries} = body}})
       when is_list(entries) do
    if body["truncated"] == true or length(entries) > @maximum_tree_entries,
      do: {:error, :repository_too_large},
      else: {:ok, entries}
  end

  defp tree_entries({:ok, %{status: status} = response}) when status in @refused,
    do: refused(response)

  defp tree_entries({:ok, %{status: 404}}), do: {:error, {:github_onboarding, :not_found}}
  defp tree_entries({:ok, _other}), do: {:error, {:github_onboarding, :tree}}

  defp tree_entries({:error, {:delivery_protocol_error, :response_too_large}}),
    do: {:error, :repository_too_large}

  defp tree_entries({:error, _reason} = error), do: error

  @impl Ryker.RepositoryKnowledge.Remote
  def read(binding, repository, path, ref) do
    with {:ok, client} <- client(binding.name),
         do: file(client, repository.github_repository, path, ref)
  end

  @impl Ryker.RepositoryKnowledge.Remote
  def changes(binding, repository, base, head) do
    path = "/repos/#{repository.github_repository}/compare/#{base}...#{head}"

    with {:ok, client} <- client(binding.name),
         do: client |> get(path) |> compared()
  end

  defp compared({:ok, %{status: 200, body: %{"files" => files}}}) when is_list(files) do
    if length(files) >= @maximum_compared_files,
      do: {:ok, :unknown},
      else: {:ok, Enum.flat_map(files, &changed_paths/1)}
  end

  defp compared({:ok, %{status: 200, body: %{}}}), do: {:ok, []}

  # The written commit is gone, after a force push.
  defp compared({:ok, %{status: status}}) when status in [404, 422], do: {:ok, :unknown}

  defp compared({:ok, %{status: status} = response}) when status in @refused,
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

  # GitHub turned the request away. Its rate limits answer 403 as well as
  # 429, and are a wait. Any other refusal is a permission the App lacks.
  defp refused(response) do
    if Transport.rate_limited?(response),
      do: {:error, {:github_onboarding, :rate_limited}},
      else: {:error, {:github_onboarding, :permission}}
  end

  # -- Files -----------------------------------------------------------------------

  defp file(client, slug, path, ref) do
    encoded =
      path
      |> String.split("/")
      |> Enum.map_join("/", &URI.encode(&1, fn character -> URI.char_unreserved?(character) end))

    query = URI.encode_query(%{"ref" => ref})

    case get(client, "/repos/#{slug}/contents/#{encoded}?#{query}") do
      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64"}}}
      when is_binary(content) ->
        decode_file(content)

      # A directory, a submodule, or a file over 1 MB, which GitHub sends
      # without its content: there, but nothing Ryker can read.
      {:ok, %{status: 200}} ->
        {:error, :source_unavailable}

      {:ok, %{status: status} = response} when status in @refused ->
        refused(response)

      {:ok, _other} ->
        {:error, {:github_onboarding, :response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_file(content) do
    with {:ok, decoded} <- Base.decode64(String.replace(content, "\n", "")),
         true <- byte_size(decoded) <= @maximum_source_bytes and String.valid?(decoded) do
      {:ok, decoded}
    else
      _too_large_or_invalid -> {:error, :source_unavailable}
    end
  end

  # -- Plumbing --------------------------------------------------------------------

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
      token_provider: fn -> InstallationTokens.token(binding_name, :source_read) end
    })
  end

  # Every request is a read.
  defp get(client, path), do: requester().request(client, :get, path, nil, @headers)

  # GitHub itself; in tests, the replies each test records (config/test.exs).
  defp requester, do: Application.get_env(:ryker, :github_files_requester, JSONClient)

  defp encode_ref(ref), do: URI.encode(ref, &URI.char_unreserved?/1)
end
