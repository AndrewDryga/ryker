defmodule Ryker.Skills.GitHub do
  @moduledoc "Preview a public GitHub procedure at an immutable commit. No GitHub credentials or redirects."
  alias Ryker.Config
  alias Ryker.Delivery
  alias Ryker.Skills
  alias Ryker.Skills.Document

  @commit ~r/\A[0-9a-f]{40}\z/
  @segment ~r/\A[a-zA-Z0-9_.-]+\z/

  @spec preview(String.t()) :: {:ok, map()} | {:error, atom()}
  def preview(url) do
    read = Config.get_env(:public_skill_reader, &read/3)

    with {:ok, {repo, ref, path}} <- location(url),
         {:ok, revision} <-
           read.(
             "https://api.github.com/repos/#{repo}/commits/#{ref}",
             "application/vnd.github.sha",
             8192
           ),
         commit = String.trim(revision),
         true <- Regex.match?(@commit, commit),
         {:ok, document} <-
           read.(
             "https://raw.githubusercontent.com/#{repo}/#{commit}/#{path}",
             "text/plain",
             32_768
           ),
         {:ok, skill} <- Document.parse(document) do
      {:ok, Map.put(skill, "source", "https://github.com/#{repo}/blob/#{commit}/#{path}")}
    else
      false -> {:error, :invalid_revision}
      {:error, reason} -> {:error, reason}
    end
  end

  # Keep the origin, commit and reviewed bytes together. A different source
  # must never take over a name that operators already enabled.
  @spec install(map(), map()) :: {:ok, map()} | {:error, atom()}
  def install(installed, %{"name" => name, "document" => document, "source" => source} = preview) do
    with {:ok, skill} <- Document.parse(document),
         {:ok, {repo, commit, path}} <- location(source),
         true <-
           Regex.match?(@commit, commit) and
             preview ==
               Map.put(skill, "source", "https://github.com/#{repo}/blob/#{commit}/#{path}"),
         :ok <- available(installed, name, repo, path) do
      Skills.put_document(installed, preview)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _invalid -> {:error, :invalid_skill}
    end
  end

  def install(_installed, _preview), do: {:error, :invalid_skill}

  defp available(installed, name, repo, path) do
    cond do
      not Map.has_key?(installed, name) ->
        if(name in Skills.names(%{}), do: {:error, :skill_name_taken}, else: :ok)

      match?({:ok, {^repo, _, ^path}}, location(installed[name]["source"])) ->
        :ok

      true ->
        {:error, :skill_name_taken}
    end
  end

  defp location(url) when is_binary(url) and byte_size(url) <= 2048 do
    with %URI{scheme: "https", host: "github.com", userinfo: nil, port: 443, path: path}
         when is_binary(path) <- URI.parse(url),
         [owner, repository | rest] <- String.split(String.trim(path, "/"), "/"),
         true <- Enum.all?([owner, repository | rest], &valid_segment?/1),
         {:ok, ref, file} <- file(rest) do
      {:ok, {String.downcase(owner <> "/" <> repository), ref, file}}
    else
      _invalid -> {:error, :invalid_url}
    end
  end

  defp location(_url), do: {:error, :invalid_url}

  defp valid_segment?(part), do: part not in [".", ".."] and Regex.match?(@segment, part)
  defp file([]), do: {:ok, "HEAD", "SKILL.md"}
  defp file(["tree", ref | directory]), do: {:ok, ref, Enum.join(directory ++ ["SKILL.md"], "/")}

  defp file(["blob", ref | path]) do
    if List.last(path) == "SKILL.md", do: {:ok, ref, Enum.join(path, "/")}, else: :error
  end

  defp file(_other), do: :error

  defp read(url, accept, limit) do
    request = Delivery.HTTPClient.build(:get, url, [{"user-agent", "ryker"}, {"accept", accept}])

    case Delivery.HTTPClient.stream(request, Ryker.CoopFinch, 10_000, limit) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} when status in [404, 422] -> {:error, :skill_not_found}
      {:ok, %{status: status}} when status in [403, 429] -> {:error, :github_limited}
      {:error, {:delivery_protocol_error, :response_too_large}} -> {:error, :skill_too_large}
      _other -> {:error, :github_unavailable}
    end
  end
end
