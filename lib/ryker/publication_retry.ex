defmodule Ryker.PublicationRetry do
  @moduledoc "Finite, payload-free facts from a worker's retained publication retry."

  @stages %{
    "publication_retry_failed" => "publishing the reviewed change",
    "publication_credentials_failed" => "preparing private Git credentials",
    "publication_grant_failed" => "requesting a fresh publication token",
    "publication_candidate_failed" => "reading the retained reviewed commit",
    "publication_repository_failed" => "checking GitHub repository access",
    "publication_pull_request_lookup_failed" => "looking up the existing pull request",
    "publication_branch_lookup_failed" => "reading the remote Git branch",
    "publication_lfs_upload_failed" => "uploading Git LFS objects",
    "publication_git_push_failed" => "pushing the reviewed commit",
    "publication_pull_request_write_failed" => "creating or updating the pull request",
    "publication_pull_request_confirmation_failed" => "confirming the pull request's commit"
  }

  def reason(%{"error_code" => code} = operation) do
    case diagnosis(code, status(operation["error_detail"])) do
      nil -> nil
      facts -> {:publication_worker_retry, facts.code, facts.http_status}
    end
  end

  def reason(_operation), do: nil

  def diagnosis(code, status) when is_integer(status) and (status == 0 or status in 100..599) do
    case @stages[code] do
      nil -> nil
      stage -> %{code: code, http_status: status, stage: stage}
    end
  end

  def diagnosis(_code, _status), do: nil

  def facts(detail) when is_binary(detail) and byte_size(detail) <= 256 do
    case Regex.run(
           ~r/\A\{:publication_worker_retry,\s*"([a-z_]{1,80})",\s*(0|[1-5]\d{2})\}\z/,
           detail
         ) do
      [_, code, status] -> diagnosis(code, String.to_integer(status))
      _unrecognized -> nil
    end
  end

  def facts(_detail), do: nil

  defp status(detail) when is_binary(detail) and byte_size(detail) <= 256 do
    case Regex.run(~r/\APublication stage: [a-z_]+\. HTTP status: ([1-5]\d{2})\.\z/, detail) do
      [_, status] -> String.to_integer(status)
      _other -> 0
    end
  end

  defp status(_detail), do: 0
end
