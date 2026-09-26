defmodule Ryker.GitHub.Client.Checks do
  @moduledoc """
  The check state of one commit: every check run and every commit status
  GitHub holds for it, summarized as none, pending, passing or failing.

  Check runs are read across every bounded page until GitHub's own total is
  reached; a short page before that total, or a page GitHub cannot describe,
  is an error rather than a smaller count.
  """

  alias Ryker.GitHub.Client
  alias Ryker.GitHub.Client.Transport

  @maximum_pages 100
  @page_size 100

  @spec summary(Client.t(), String.t(), String.t()) ::
          {:ok,
           %{
             failed: non_neg_integer(),
             passed: non_neg_integer(),
             state: String.t(),
             total: non_neg_integer()
           }}
          | {:error, term()}
  def summary(client, repository, sha) do
    with {:ok, check_runs} <- check_runs(client, repository, sha),
         {:ok, commit_statuses} <- commit_statuses(client, repository, sha) do
      {:ok, summarize_checks(check_runs, commit_statuses)}
    end
  end

  defp check_runs(client, repository, sha, page \\ 1, accumulated \\ []) do
    path =
      "/repos/#{repository}/commits/#{sha}/check-runs?per_page=#{@page_size}&page=#{page}"

    with {:ok, response} <- Transport.request(client, :get, path, nil),
         {:ok, runs, total} <- check_run_page(response),
         values <- accumulated ++ runs do
      cond do
        length(values) >= total -> {:ok, Enum.take(values, total)}
        length(runs) < @page_size -> {:error, {:github_protocol_error, :check_runs_count}}
        page >= @maximum_pages -> {:error, {:github_reconciliation_incomplete, :check_runs}}
        true -> check_runs(client, repository, sha, page + 1, values)
      end
    end
  end

  defp check_run_page(%{
         body: %{"check_runs" => runs, "total_count" => total},
         status: 200
       })
       when is_list(runs) and is_integer(total) and total >= 0 do
    if Enum.all?(runs, &valid_check_run?/1),
      do: {:ok, runs, total},
      else: {:error, {:github_protocol_error, :check_runs}}
  end

  defp check_run_page(%{status: 200}), do: {:error, {:github_protocol_error, :check_runs}}
  defp check_run_page(response), do: Transport.error(response)

  defp valid_check_run?(%{"conclusion" => conclusion, "status" => status}) do
    status in ~w(queued in_progress completed pending requested waiting) and
      (is_nil(conclusion) or
         conclusion in ~w(success neutral skipped failure cancelled timed_out action_required stale startup_failure))
  end

  defp valid_check_run?(_run), do: false

  defp commit_statuses(client, repository, sha) do
    path = "/repos/#{repository}/commits/#{sha}/status?per_page=#{@page_size}"

    with {:ok, response} <- Transport.request(client, :get, path, nil) do
      commit_status_response(response)
    end
  end

  defp commit_status_response(%{body: %{"statuses" => statuses}, status: 200})
       when is_list(statuses) do
    if Enum.all?(statuses, &valid_commit_status?/1),
      do: {:ok, statuses},
      else: {:error, {:github_protocol_error, :commit_statuses}}
  end

  defp commit_status_response(%{status: 200}),
    do: {:error, {:github_protocol_error, :commit_statuses}}

  defp commit_status_response(response), do: Transport.error(response)

  defp valid_commit_status?(%{"state" => state}),
    do: state in ~w(error failure pending success)

  defp valid_commit_status?(_status), do: false

  defp summarize_checks(check_runs, statuses) do
    outcomes = Enum.map(check_runs, &check_run_outcome/1) ++ Enum.map(statuses, &status_outcome/1)
    total = length(outcomes)
    failed = Enum.count(outcomes, &(&1 == :failed))
    passed = Enum.count(outcomes, &(&1 == :passed))

    state =
      cond do
        total == 0 -> "none"
        failed > 0 -> "failing"
        passed == total -> "passing"
        true -> "pending"
      end

    %{failed: failed, passed: passed, state: state, total: total}
  end

  defp check_run_outcome(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion in ~w(success neutral skipped),
       do: :passed

  defp check_run_outcome(%{"status" => "completed"}), do: :failed
  defp check_run_outcome(_run), do: :pending

  defp status_outcome(%{"state" => "success"}), do: :passed
  defp status_outcome(%{"state" => state}) when state in ~w(error failure), do: :failed
  defp status_outcome(_status), do: :pending
end
