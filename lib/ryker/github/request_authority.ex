defmodule Ryker.GitHub.RequestAuthority do
  @moduledoc "Current authority for queued GitHub requests at model submission."
  alias Ryker.GitHub.IssueTriageGrant
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Repo

  def check_entry(
        %{
          source_kind: "github",
          execution_mode: :live,
          actor_kind: kind,
          engagement_receipt: receipt
        } = entry
      )
      when kind in [:user, :bot] and is_map(receipt) do
    if Repo.exists?(
         Ingress.Inbox.Entry.Query.by_id(entry.id)
         |> Ingress.Inbox.Entry.Query.withdrawn_github_requests([entry.event_ref])
       ),
       do: {:error, :github_request_withdrawn},
       else: :ok
  end

  def check_entry(entry), do: IssueTriageGrant.check_entry(entry)

  def check_turn(%{episode: %{execution_mode: :live}} = claim) do
    inputs = Records.TaskInstruction.current_inputs(claim)

    refs =
      for %{"content" => %{"source" => %{"kind" => "github"}, "event_ref" => ref}} <- inputs,
          do: ref

    if refs != [] and
         Repo.exists?(
           Ingress.Inbox.Entry.Query.by_episode_id(claim.episode.id)
           |> Ingress.Inbox.Entry.Query.withdrawn_github_requests(refs)
         ) do
      {:error, :github_request_withdrawn}
    else
      check_automatic_inputs(claim, inputs)
    end
  end

  def check_turn(_claim), do: :ok

  defp check_automatic_inputs(claim, inputs) do
    inputs
    |> Enum.filter(&(get_in(&1, ["content", "actor", "ref"]) == "system:github-issue-triage"))
    |> Enum.reduce_while(:ok, fn input, :ok ->
      with {:ok, {entry, _event}} <-
             Records.TaskInstruction.fetch_source(claim, input["source_event_id"]),
           :ok <- IssueTriageGrant.check_entry(entry) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end
