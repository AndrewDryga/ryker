defmodule Ryker.GitHubActions.IssueMessageWorker do
  @moduledoc "Keeps one GitHub issue comment current across restarts and lost responses."
  use Ryker.PollingWorker, lane: :github_issue_messages, interval: :interval_ms
  alias Ryker.Backoff
  alias Ryker.Delivery
  alias Ryker.GitHub
  alias Ryker.GitHubActions.IssueMessages
  alias Ryker.Options

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def options!(options) do
    options =
      Options.normalize!(
        options,
        [:bindings, :base_url, :interval_ms],
        [],
        "invalid issue message options"
      )
      |> Map.put_new(:bindings, %{})
      |> Map.put_new(:base_url, nil)
      |> Map.put_new(:interval_ms, 5_000)

    unless is_map(options.bindings) and (is_nil(options.base_url) or is_binary(options.base_url)) and
             options.interval_ms in 100..60_000,
           do: raise(ArgumentError, "invalid issue message options")

    options
  end

  @impl Ryker.PollingWorker
  def setup(options), do: {:ok, options!(options)}

  @impl Ryker.PollingWorker
  def poll(options) do
    case run_once(options) do
      {:ok, :updated} -> 0
      _idle_or_deferred -> options.interval_ms
    end
  end

  def run_once(options) do
    case IssueMessages.claim_next(Map.keys(options.bindings)) do
      {:ok, nil} -> {:ok, :idle}
      {:ok, claimed} -> deliver(claimed, options)
      error -> error
    end
  end

  defp deliver(claimed, options) do
    adapters = %{
      "github" => %{
        message_publisher: GitHub.Publisher,
        reaction_publisher: GitHub.Publisher,
        binding: %{bindings: options.bindings}
      }
    }

    with {:ok, projected} <- IssueMessages.request(claimed, options.base_url),
         {:ok, receipt} <-
           Delivery.ReconciledMessage.publish(
             projected.request,
             projected.workflow.external_receipt,
             projected.workflow.rendered_fingerprint,
             adapters
           ),
         {:ok, _saved} <- IssueMessages.mark(projected, receipt) do
      {:ok, :updated}
    else
      {:error, reason} ->
        seconds = Backoff.delay(claimed.attempt_count, 10, 900, 8)

        seconds =
          case Delivery.Retry.rate_limited(reason) do
            {:ok, retry} when is_integer(retry) -> max(seconds, retry)
            _ordinary -> seconds
          end

        with {:ok, _saved} <- IssueMessages.failed(claimed, reason, seconds), do: {:ok, :deferred}
    end
  end
end
