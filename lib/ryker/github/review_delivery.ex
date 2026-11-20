defmodule Ryker.GitHub.ReviewDelivery do
  @moduledoc "Reconciles a terminal PR reply to the native review this turn already submitted."
  alias Ryker.Delivery
  alias Ryker.GitHub.{Renderer, Target}
  alias Ryker.StateTools
  alias Ryker.Work

  def receipt(
        %{session: session, turn: %{continuation: %{"kind" => "complete"}} = turn},
        %Delivery.Request{
          transport: "github",
          kind: :message,
          also_answered: [],
          artifacts: [],
          document: %{"message" => message}
        } = request
      ) do
    with %{
           "repository_read_only" => true,
           "source" => %{"binding" => %{"selected_commit" => head}}
         }
         when is_binary(head) <- session.worker_job_document,
         {:ok, %{thread: %{kind: "pull", number: number}}} <- Target.parse(request),
         true <- turn.delivery_document["message"] == message,
         true <- get_in(turn.delivery_document, ["outcome", "artifact_refs"]) in [nil, []],
         {:ok, ^message} <- Renderer.render(request.document),
         {:ok, %{"review_id" => id}} <-
           StateTools.CallLog.fetch_submitted_github_review(turn, %{
             "conversation_ref" => request.conversation_ref,
             "thread_ref" => request.thread_ref,
             "number" => number,
             "head_sha" => head
           }) do
      Work.DeliveryReceipt.new(
        request.ref,
        "github",
        request.conversation_ref,
        request.thread_ref,
        "github:pull_request_review:#{id}"
      )
    else
      _ordinary_reply -> :not_found
    end
  end

  def receipt(_claim, _request), do: :not_found
end
