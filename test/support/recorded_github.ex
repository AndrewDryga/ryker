defmodule Ryker.TestSupport.RecordedGitHub do
  @moduledoc """
  GitHub's REST API as `Ryker.GitHub.RepositoryFiles` meets it, in tests: its
  configured requester (config/test.exs), so no test reaches GitHub.

  A test lists the replies GitHub gives, in order, each with the request it
  answers (`reply/1`): `{method, path, {:ok, %{status: ..., body: ...,
  headers: ...}}}`, or `{method, path, {:error, reason}}` for a request that
  never got an answer. A request other than the next one listed is refused
  and never answered, and `unanswered/0` names the replies nothing asked for.
  The replies live in the calling process, so tests that use it can run
  together.
  """

  @spec reply([{atom(), String.t(), {:ok, map()} | {:error, term()}}]) :: :ok
  def reply(replies) when is_list(replies) do
    Process.put(__MODULE__, %{replies: replies})
    :ok
  end

  @doc "The listed replies no request asked for."
  def unanswered, do: Enum.map(state().replies, fn {method, path, _reply} -> {method, path} end)

  def request(_client, method, path, _document, _headers) do
    case state().replies do
      [{^method, ^path, reply} | rest] ->
        Process.put(__MODULE__, %{replies: rest})
        reply

      _other ->
        {:error, {:unexpected_github_request, method, path}}
    end
  end

  defp state, do: Process.get(__MODULE__, %{replies: []})
end
