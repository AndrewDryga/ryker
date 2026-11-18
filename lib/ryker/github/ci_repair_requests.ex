defmodule Ryker.GitHub.CIRepairRequests do
  @moduledoc "Freezes each automatic CI repair as ordinary ingress with host-owned scope."
  alias Ryker.Config
  alias Ryker.GitHub.{CIRepair, CIRepairRound}
  alias Ryker.Ingress
  alias Ryker.Repo

  def record(%CIRepair{} = repair, configured, pull) do
    round_id = Repo.generate_id()
    now = Repo.now!()

    snapshot = %{
      "pull" => pull,
      "ordinal" => repair.rounds + 1,
      "policy" => Atom.to_string(configured.repository.github_ci_repair)
    }

    reference = "github-ci-repair:" <> round_id
    runtime = Config.get_env(:github) || %{}
    binding = get_in(runtime, [:server, :bindings, repair.binding_ref])

    with %{work_profile: %Ingress.WorkProfile{}} <- binding,
         true <-
           binding.repository_id == repair.repository_id and
             binding.installation_id == repair.installation_id,
         {:ok, input} <-
           Ingress.Input.new(%{
             actor: %{kind: :system, ref: "system:" <> reference},
             source: %{kind: "github", ref: repair.binding_ref},
             content: %{
               "event_name" => "ryker_ci_repair",
               "request" => prompt(snapshot),
               "repair_round_id" => round_id,
               "payload" => %{
                 "installation" => %{"id" => repair.installation_id},
                 "repository" => %{
                   "id" => repair.repository_id,
                   "full_name" => configured.repository.github_repository
                 }
               }
             },
             destination: %{
               transport: "github",
               conversation_ref:
                 "github:#{repair.binding_ref}:repository:#{repair.repository_id}",
               thread_ref: "github:#{repair.binding_ref}:pull:#{repair.number}"
             },
             event_kind: :message,
             event_ref: reference,
             native_input_id: reference,
             source_item_ref: reference,
             source_capabilities: %{},
             occurred_at: now,
             occurred_at_source: :ingress,
             revision: 1
           }),
         {:ok, %{entry: entry}} <-
           Ingress.Inbox.record(input,
             work_profile: binding.work_profile,
             engagement_receipt: %{
               "reason" => "repository_ci_policy",
               "policy" => snapshot["policy"]
             }
           ) do
      target = %{
        "kind" => "existing_pull_request",
        "repository_ref" => repair.repository_ref,
        "repository_id" => repair.repository_id,
        "installation_id" => repair.installation_id,
        "app_actor_id" => configured.binding.ryker_actor_id,
        "binding_ref" => repair.binding_ref,
        "number" => repair.number,
        "head_ref" => "refs/heads/" <> pull["branch"],
        "base_ref" => "refs/heads/" <> pull["base_branch"],
        "head_commit" => pull["head"],
        "source_input_id" => entry.id,
        "reason" => "automatic_ci_repair",
        "findings" => [],
        "authorization" => %{
          "kind" => "repository_ci_policy",
          "repair_id" => repair.id,
          "round_id" => round_id
        }
      }

      CIRepairRound.Changeset.insert(%{
        id: round_id,
        repair_id: repair.id,
        generation: repair.generation,
        ordinal: repair.rounds + 1,
        entry_id: entry.id,
        head: pull["head"],
        snapshot: Map.put(snapshot, "target", target),
        inserted_at: now
      })
      |> Repo.insert()
    else
      {:error, reason} -> {:error, reason}
      _unavailable -> {:error, :ci_repair_work_unavailable}
    end
  end

  @doc "A model cannot replace the admitted repair scope with a broader task."
  def pin(%Ingress.Inbox.Entry{content: %{"event_name" => "ryker_ci_repair"}} = entry, payload) do
    with {:ok, round} <- Repo.fetch(CIRepairRound.Query.by_entry_id(entry.id)) do
      {:ok,
       payload
       |> Map.put("prompt", prompt(round.snapshot))
       |> Map.put("purpose", "implementation")}
    end
  end

  def pin(_entry, payload), do: {:ok, payload}

  defp prompt(snapshot) do
    pull = snapshot["pull"]

    """
    The repository operator enabled automatic CI repair for this PR. Repair PR ##{pull["number"]} at commit #{pull["head"]}; this is round #{snapshot["ordinal"]} of at most two for this failure episode.
    Read the failed check logs first. Reproduce the failure on this PR and compare the base branch before editing. Fix only a failure caused by this PR. If the failure is unrelated base code, missing credentials, infrastructure, or cannot be reproduced, explain the evidence and stop without speculative edits.
    Start engineering work using this current input's instruction_ref. Preserve the existing PR branch and other people's changes. Run the relevant regression test and repository gate. Never weaken or remove tests, bypass checks, expose secrets, merge, or approve the PR. Publication is allowed only after the host rechecks the repository policy, skip label and exact head.
    Report the failure, reproduction, focused fix, checks run and any remaining uncertainty. If ryker:no-ci-fix is applied or automatic repair is disabled, stop safely and retain the work.
    """
  end
end
