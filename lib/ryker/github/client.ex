defmodule Ryker.GitHub.Client do
  @moduledoc """
  Bounded GitHub REST adapter for durable comment and reaction delivery.

  Comment lookup never reports absence until every bounded page was inspected;
  this preserves the publisher's lost-response reconciliation guarantee.

  This module is the `Ryker.GitHub.API` surface bindings configure as `api:`:
  the client struct and every call a binding makes. The work behind each call
  lives with what it talks to: `Client.Comments` the issue comments, pull
  reviews, review replies and reactions; `Client.PullRequests` the pull
  requests and reviews on an exact head, with `Client.Checks` their check
  state; `Client.Actions` the workflow run attempts; `Client.Context` and
  `Client.Search` what the model may read. `Client.Transport` sends each
  request and reads a failed reply, and `Client.Fields` holds the argument and
  reply checks.
  """

  @behaviour Ryker.GitHub.API

  alias Ryker.GitHub.Client.{Actions, Comments, Context, PullRequests, Search}

  @fields [:http, :requester]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{http: term(), requester: module()}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         client <- struct!(__MODULE__, attributes),
         true <- requester?(client.requester) do
      {:ok, client}
    else
      false -> {:error, {:invalid_github_client, :requester}}
      {:error, _reason} = error -> error
    end
  end

  # --- issue comments, pull reviews, review replies and reactions ----------

  @impl true
  defdelegate find_issue_comment(client, repository, number, marker), to: Comments

  @impl true
  defdelegate create_issue_comment(client, repository, number, body), to: Comments

  @impl true
  defdelegate update_issue_comment(client, repository, comment_id, body), to: Comments

  @impl true
  defdelegate find_pull_review(client, repository, number, marker), to: Comments

  @impl true
  defdelegate create_pull_review(client, repository, number, body), to: Comments

  @impl true
  defdelegate update_pull_review(client, repository, number, review_id, body), to: Comments

  @impl true
  defdelegate find_review_reply(client, repository, number, root_id, marker), to: Comments

  @impl true
  defdelegate create_review_reply(client, repository, number, root_id, body), to: Comments

  @impl true
  defdelegate update_review_comment(client, repository, comment_id, body), to: Comments

  @impl true
  defdelegate add_issue_comment_reaction(client, repository, comment_id, emoji_name),
    to: Comments

  @impl true
  defdelegate add_review_comment_reaction(client, repository, comment_id, emoji_name),
    to: Comments

  # --- pull requests --------------------------------------------------------

  @impl true
  defdelegate find_open_pull_request(client, repository, owner, branch), to: PullRequests

  @impl true
  defdelegate create_draft_pull_request(client, repository, title, body, head, base),
    to: PullRequests

  @impl true
  defdelegate get_pull_request(client, repository, number), to: PullRequests

  @impl true
  defdelegate get_publication_status(client, repository, number), to: PullRequests

  @doc "Publishes one review tied to the exact pull-request head SHA."
  @spec submit_review(t(), String.t(), pos_integer(), String.t(), String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  defdelegate submit_review(client, repository, number, head_sha, event, body, comments),
    to: PullRequests

  # --- Actions runs ---------------------------------------------------------

  @doc "Reads one exact Actions run attempt and its bounded jobs."
  @spec read_ci_attempt(t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  defdelegate read_ci_attempt(client, repository, run_id, attempt), to: Actions

  @doc "Reruns failed jobs only when the named attempt is still current."
  @spec rerun_failed_ci(t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  defdelegate rerun_failed_ci(client, repository, run_id, attempt), to: Actions

  @doc "Cancels a run only when the named attempt is still current and active."
  @spec cancel_ci(t(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  defdelegate cancel_ci(client, repository, run_id, attempt), to: Actions

  # --- what the model may read ----------------------------------------------

  @impl true
  defdelegate read_context(client, request), to: Context

  @impl true
  defdelegate search(client, request), to: Search

  # --- construction ---------------------------------------------------------

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      normalize_attributes(Map.new(attributes))
    else
      {:error, {:invalid_github_client, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_github_client, :fields}}
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_github_client, :fields}}

  defp requester?(requester) do
    is_atom(requester) and Code.ensure_loaded?(requester) and
      function_exported?(requester, :request, 5)
  end
end
