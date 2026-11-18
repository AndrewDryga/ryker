defmodule Ryker.GitHub.IssueTriageWorker do
  @moduledoc "Quiet bounded backfill, current issue refresh, and opted-in read-only triage."
  use Ryker.PollingWorker, lane: :github_issue_triage, interval: :interval_ms
  alias Ryker.Adapter
  alias Ryker.GitHub.{Client, IssueIndex, IssueSnapshot}
  alias Ryker.GitHubActions
  alias Ryker.Options

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) do
    options =
      Options.normalize!(
        options,
        [:bindings, :interval_ms, :api],
        [],
        "invalid issue triage options"
      )
      |> Map.put_new(:bindings, %{})
      |> Map.put_new(:interval_ms, 5_000)
      |> Map.put_new(:api, Client.IssueTriage)

    unless is_map(options.bindings) and options.interval_ms in 100..60_000 and
             Adapter.implements?(options.api, repository: 3, read: 3, page: 3),
           do: raise(ArgumentError, "invalid issue triage options")

    options
  end

  @impl Ryker.PollingWorker
  def setup(options), do: {:ok, options!(options)}
  @impl Ryker.PollingWorker
  def poll(options) do
    case run_once(options) do
      {:ok, :updated} -> 0
      _idle -> options.interval_ms
    end
  end

  def run_once(options) do
    Enum.each(Map.keys(options.bindings), fn name ->
      case IssueIndex.configuration(name) do
        {:ok, %{repository: %{github_issue_triage: true}} = configured} ->
          IssueIndex.ensure(configured)

        _disabled ->
          :ok
      end
    end)

    case IssueIndex.claim_next(Map.keys(options.bindings)) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, claimed} -> process(claimed, options)
      error -> error
    end
  end

  defp process(claimed, options) do
    client = Map.fetch!(options.bindings, claimed.binding_ref).read_client

    with {:ok, configured} <- IssueIndex.configuration(claimed.binding_ref),
         true <-
           configured.binding.repository_id == claimed.repository_id and
             configured.binding.installation_id == claimed.installation_id,
         :ok <-
           options.api.repository(
             client,
             configured.repository.github_repository,
             claimed.repository_id
           ),
         {:ok, _saved} <- advance(claimed, configured, client, options.api) do
      {:ok, :updated}
    else
      _unavailable ->
        case IssueIndex.release(claimed, 60) do
          {:ok, _saved} -> {:ok, :deferred}
          error -> error
        end
    end
  end

  defp advance(claimed, configured, client, api) do
    case IssueIndex.fetch_next_issue(claimed) do
      {:ok, issue} ->
        refresh(claimed, issue, configured, client, api)

      {:error, :not_found} when claimed.page <= 5 and not claimed.backfill_complete ->
        with {:ok, page} <-
               api.page(client, configured.repository.github_repository, claimed.page),
             do: IssueIndex.backfilled(claimed, configured, page)

      {:error, :not_found} ->
        IssueIndex.release(claimed, 60)
    end
  end

  defp refresh(claimed, issue, configured, client, api) do
    case api.read(client, configured.repository.github_repository, issue.number) do
      {:ok, document} ->
        refresh_document(claimed, issue, configured, document)

      {:error, :issue_unavailable} ->
        with {:ok, _saved} <- IssueIndex.refreshed(claimed, issue, configured, nil, {nil, nil}),
             do: IssueIndex.settled(claimed, issue, configured, nil)

      error ->
        error
    end
  end

  defp refresh_document(claimed, issue, configured, document) do
    with {:ok, _saved} <-
           IssueIndex.refreshed(
             claimed,
             issue,
             configured,
             document,
             IssueIndex.embedding(document)
           ) do
      case triage(issue, configured, document) do
        {:ok, digest} -> IssueIndex.settled(claimed, issue, configured, digest)
        {:error, _busy_or_unavailable} -> IssueIndex.settled(claimed, issue, configured, nil, 60)
      end
    end
  end

  defp triage(%{triage_pending: false}, _configured, _document), do: {:ok, nil}
  defp triage(_issue, %{repository: %{github_issue_triage: false}}, _document), do: {:ok, nil}
  defp triage(_issue, _configured, %{"issue" => %{"state" => "closed"}}), do: {:ok, nil}

  defp triage(issue, configured, document) do
    with false <- document["issue"]["body_truncated"],
         {:ok, snapshot} <- IssueSnapshot.prepare(configured, issue.number, document["issue"]),
         digest <- IssueSnapshot.content_digest(snapshot),
         {:ok, _request} <- GitHubActions.IssueWorkflows.auto_triage(configured, snapshot) do
      {:ok, digest}
    else
      true -> {:ok, nil}
      error -> error
    end
  end
end
