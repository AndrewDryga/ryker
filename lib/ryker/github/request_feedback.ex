defmodule Ryker.GitHub.RequestFeedback do
  @moduledoc "Fixed acknowledgments at the authenticated request's own GitHub discussion."
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.GitHub.{Client, InertText, Publisher, Target}

  def deliver(binding, input, outcome, client, api \\ Client) do
    ref =
      "github-request:" <>
        CanonicalJSON.digest([binding.name, input.native_input_id, input.revision])

    with {:ok, request} <-
           Delivery.Request.new(%{
             conversation_ref: input.destination.conversation_ref,
             thread_ref: input.destination.thread_ref,
             document: %{"message" => message(outcome)},
             kind: :message,
             ref: ref,
             source_item_ref: nil,
             transport: "github"
           }),
         {:ok, target} <- Target.parse(request),
         true <- target.binding == binding.name and target.repository_id == binding.repository_id,
         :ok <-
           post(
             api,
             client,
             binding.repository_full_name,
             target.thread,
             Publisher.marker(ref),
             message(outcome)
           ) do
      consume_label(outcome, api, client, binding.repository_full_name, target.thread.number)
    else
      false -> {:error, :github_feedback_target_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp consume_label(:review_requested, api, client, repository, number),
    do: api.remove_pull_label(client, repository, number, "ryker:review")

  defp consume_label(_outcome, _api, _client, _repository, _number), do: :ok

  defp message(:review_requested),
    do: "Review request accepted. I’ll review this pull request and post my findings."

  defp message({:denied, :maintain}) do
    "I couldn’t accept this confirmation. A repository Maintainer or Admin needs to post the confirmation command."
  end

  defp message({:denied, :write}) do
    "I couldn’t start this request. Someone with Write access or higher needs to ask me in this repository."
  end

  defp message({:confirmation, "confirmed"}), do: "Confirmed. I’ve accepted the offer."
  defp message({:confirmation, "duplicate"}), do: "This offer was already confirmed."

  defp message({:confirmation, "invalid"}) do
    "I couldn’t accept this confirmation. Copy the exact command from an available offer in this discussion. If the offer is no longer available, ask me for a new one."
  end

  defp post(
         api,
         client,
         repository,
         %{kind: "review_thread", number: number, review_root_id: root},
         marker,
         message
       ) do
    case api.find_review_reply(client, repository, number, root, marker) do
      {:ok, _id} ->
        :ok

      :not_found ->
        with {:ok, _id} <-
               api.create_review_reply(
                 client,
                 repository,
                 number,
                 root,
                 InertText.inert(message) <> "\n\n" <> marker
               ),
             do: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(api, client, repository, %{number: number}, marker, message) do
    case api.find_issue_comment(client, repository, number, marker) do
      {:ok, _id} ->
        :ok

      :not_found ->
        with {:ok, _id} <-
               api.create_issue_comment(
                 client,
                 repository,
                 number,
                 InertText.inert(message) <> "\n\n" <> marker
               ),
             do: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
