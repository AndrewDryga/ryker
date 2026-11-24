defmodule Ryker.GitHubActions.IssueMessages do
  @moduledoc "Leased projection of one issue comment, separate from the work it describes."
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.ErrorDetail
  alias Ryker.GitHubActions.IssueProgress
  alias Ryker.GitHubActions.IssueRequest
  alias Ryker.GitHubActions.IssueWorkflow
  alias Ryker.GitHubActions.IssueWorkflows
  alias Ryker.Lease
  alias Ryker.Repo
  alias Ryker.Settings

  def claim_next(bindings) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case Repo.fetch(IssueWorkflow.Query.next_claimable(now, bindings)) do
        {:error, :not_found} ->
          nil

        {:ok, workflow} ->
          update!(workflow, %{
            lease_ref: Repo.generate_id(),
            lease_expires_at: DateTime.add(now, 60),
            attempt_count: workflow.attempt_count + 1
          })
      end
    end)
  end

  def request(claimed, base_url) do
    Repo.transaction(fn ->
      workflow = fetch_and_lock_claim!(claimed)
      authorize!(workflow)

      request =
        workflow.current_request_id
        |> fetch_request()
        |> IssueProgress.displayed_request()
        |> IssueProgress.refresh()

      plan = IssueWorkflows.current_plan(workflow.current_plan_id)
      progress = IssueProgress.read(request)

      link =
        if is_binary(base_url) do
          String.trim_trailing(base_url, "/") <>
            "/github/actions/issue/#{workflow.binding_ref}/#{workflow.number}"
        end

      document = %{"message" => triage(progress) <> markdown(plan, progress, link)}

      {:ok, delivery} =
        Delivery.Request.new(%{
          ref: "github-issue:#{workflow.id}",
          kind: :message,
          transport: "github",
          conversation_ref: "github:#{workflow.binding_ref}:repository:#{workflow.repository_id}",
          thread_ref: "github:#{workflow.binding_ref}:issue:#{workflow.number}",
          source_item_ref: nil,
          document: document,
          frozen_at: workflow.inserted_at
        })

      %{
        workflow: workflow,
        request: delivery,
        progress: progress,
        pending: not is_nil(request) and is_nil(request.finished_at)
      }
    end)
  end

  def mark(projected, receipt) do
    with :ok <- Delivery.ReconciledMessage.validate(projected.request, receipt) do
      Repo.transaction(fn ->
        current = fetch_and_lock_claim!(projected.workflow)

        update!(current, %{
          external_receipt: receipt,
          rendered_fingerprint: CanonicalJSON.digest(projected.request.document),
          next_attempt_at: next_attempt(current, projected),
          lease_ref: nil,
          lease_expires_at: nil,
          attempt_count: 0,
          last_error: nil
        })
      end)
    end
  end

  defp next_attempt(current, projected) do
    changed =
      current.revision != projected.workflow.revision or
        current.current_request_id != projected.workflow.current_request_id

    cond do
      changed -> Repo.now!()
      projected.pending -> DateTime.add(Repo.now!(), 15)
      true -> nil
    end
  end

  def failed(claimed, reason, seconds) do
    Repo.transaction(fn ->
      claimed
      |> fetch_and_lock_claim!()
      |> update!(%{
        next_attempt_at: DateTime.add(Repo.now!(), seconds),
        lease_ref: nil,
        lease_expires_at: nil,
        last_error: ErrorDetail.detail(reason)
      })
    end)
  end

  defp fetch_and_lock_claim!(claimed) do
    current =
      claimed.id
      |> IssueWorkflow.Query.by_id()
      |> IssueWorkflow.Query.lock_for_update()
      |> Repo.fetch!()

    if Lease.held?(current, claimed.lease_ref, Repo.now!()),
      do: current,
      else: Repo.rollback(:issue_comment_lease_lost)
  end

  defp authorize!(workflow) do
    with {:ok, settings} <- Settings.fetch(),
         true <- settings.github.enabled,
         true <-
           Enum.any?(
             settings.github_bindings,
             &(&1.name == workflow.binding_ref and
                 &1.repository_id == workflow.repository_id and
                 &1.installation_id == workflow.installation_id and
                 &1.repository_ref == workflow.repository_ref)
           ),
         true <-
           Enum.any?(
             settings.repositories,
             &(&1.ref == workflow.repository_ref and &1.github_access == :available)
           ),
         do: :ok,
         else: (_revoked -> Repo.rollback(:repository_access_changed))
  end

  defp fetch_request(nil), do: nil
  defp fetch_request(id), do: id |> IssueRequest.Query.by_id() |> Repo.fetch!()

  defp update!(workflow, attributes),
    do: workflow |> IssueWorkflow.Changeset.update(attributes) |> Repo.update!()

  defp markdown(nil, progress, nil), do: status(progress)

  defp markdown(plan, progress, nil),
    do: "### Plan · version #{plan.revision}\n\n" <> plan.body <> "\n\n" <> status(progress)

  defp markdown(nil, progress, link) do
    status(progress) <>
      "\n\n[**Make a plan**](#{link}) · [**Build this**](#{link}) · [**Triage this issue**](#{link})\n\nChoose and confirm on the next page."
  end

  defp markdown(plan, progress, link) do
    "### Plan · version #{plan.revision}\n\n" <>
      plan.body <>
      "\n\n" <>
      status(progress) <>
      "\n\n[**Edit plan**](#{link}) · [**Implement plan**](#{link}) · [**Triage this issue**](#{link})\n\nReview the saved version before starting."
  end

  defp triage(%{"triage" => result}) do
    related =
      Enum.map_join(result["related"], "\n", fn item ->
        "- [##{item["number"]}](#{item["url"]}) — #{String.replace(item["relation"], "_", " ")}: #{item["evidence"]}"
      end)

    labels =
      if result["labels"] == [],
        do: "",
        else:
          "\n\nLabels: " <> Enum.join(result["labels"], ", ") <> ". " <> result["labels_status"]

    "### Issue triage\n\n" <>
      result["summary"] <> if(related == "", do: "", else: "\n\n" <> related) <> labels <> "\n\n"
  end

  defp triage(_progress), do: ""

  @doc "The same short progress label in GitHub and on its approval page."
  def status(%{"status" => "authorization_expired"}),
    do: "Automatic triage expired. A repository writer can request triage again."

  def status(%{"status" => "triage_ready"}),
    do: "Triage ready. Review the findings before starting code work."

  def status(%{"status" => "ready"}), do: "Ryker can help with this issue."
  def status(%{"status" => "queued"}), do: "Request saved. Waiting to start."
  def status(%{"status" => "planning"}), do: "Reading the issue and relevant code."

  def status(%{"status" => "plan_ready"}),
    do: "Plan ready for your review. No code changes have started."

  def status(%{"status" => "preparing"}), do: "Preparing the approved work."
  def status(%{"status" => "building"}), do: "Implementing the approved request."
  def status(%{"status" => "checking"}), do: "Checking the change and preparing its pull request."

  def status(%{"status" => "pull_request_ready", "url" => url}),
    do: "[**View pull request**](#{url})"

  def status(%{"status" => "publication_needs_attention", "url" => url}) do
    "The fix was pushed, but the PR changed or could not be verified afterward. [Review the pull request](#{url}) and Ryker's publication report."
  end

  def status(%{"status" => "needs_input"}), do: "Waiting for your answer in this issue."

  def status(%{"status" => "cancelled"}),
    do: "Work stopped. Review the issue before starting again."

  def status(%{"status" => "needs_attention"}),
    do: "Work needs attention. Read Ryker's latest reply in this issue for the next step."

  def status(_other) do
    "Work ended without a saved plan or pull request. Read the latest reply, then review and try again."
  end
end
