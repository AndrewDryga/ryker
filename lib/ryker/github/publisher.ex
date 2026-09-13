defmodule Ryker.GitHub.Publisher do
  @moduledoc """
  Publishes durable replies and reactions through a trusted GitHub repository binding.

  GitHub comment creation has no idempotency key. Each visible body therefore
  carries an opaque HTML delivery marker, and every retry searches the exact
  bound issue, pull request, or review thread before creating content.
  Reactions use GitHub's idempotent create semantics directly.
  """

  @behaviour Ryker.Delivery.Platform
  @behaviour Ryker.Delivery.MessagePublisher
  @behaviour Ryker.Delivery.ReactionPublisher

  alias Ryker.Delivery.Request
  alias Ryker.GitHub.{Renderer, Target}
  alias Ryker.Work.DeliveryReceipt

  @impl true
  def transport, do: "github"

  @impl true
  def publish_message(%Request{kind: :message} = request, binding) do
    with {:ok, target} <- Target.parse(request),
         {:ok, api, client, repository} <- client(binding, target),
         {:ok, message_ref} <- reconcile_message(api, client, repository, request, target) do
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        message_ref
      )
    end
  end

  def publish_message(_request, _binding),
    do: {:error, {:invalid_github_delivery, :message}}

  @impl Ryker.Delivery.MessagePublisher
  def update_message(%Request{kind: :message} = request, message_ref, document, binding) do
    with {:ok, target} <- Target.parse(request),
         {:ok, api, client, repository} <- client(binding, target),
         {:ok, kind, comment_id} <- message_identity(message_ref),
         :ok <- message_kind_matches_thread(kind, target.thread),
         {:ok, rendered} <- Renderer.render(document),
         body <- neutralize_mentions(rendered) <> "\n\n" <> marker(request.ref) do
      update_comment(api, client, repository, kind, comment_id, body, target.thread)
    end
  end

  def update_message(_request, _message_ref, _document, _binding),
    do: {:error, {:invalid_github_delivery, :message_update}}

  @impl true
  def publish_reaction(%Request{kind: :reaction} = request, binding) do
    with true <- Map.get(request.document, "action", "add") == "add",
         {:ok, target} <- Target.parse(request),
         {:ok, api, client, repository} <- client(binding, target),
         :ok <- react(api, client, repository, target.source_item, request.document["emoji_name"]) do
      DeliveryReceipt.new(
        request.ref,
        request.transport,
        request.conversation_ref,
        request.thread_ref,
        request.source_item_ref
      )
    else
      false -> {:error, {:invalid_github_delivery, :reaction_action}}
      {:error, _reason} = error -> error
    end
  end

  def publish_reaction(_request, _binding),
    do: {:error, {:invalid_github_delivery, :reaction}}

  @spec marker(String.t()) :: String.t()
  def marker(delivery_ref) when is_binary(delivery_ref) do
    digest = :crypto.hash(:sha256, delivery_ref) |> Base.encode16(case: :lower)
    "<!-- responder-delivery:#{digest} -->"
  end

  defp reconcile_message(api, client, repository, request, target) do
    marker = marker(request.ref)

    case find_message(api, client, repository, target.thread, marker) do
      {:ok, message_id} ->
        {:ok, message_ref(target.thread, message_id)}

      :not_found ->
        create_message(api, client, repository, request, target.thread, marker)

      {:error, reason} ->
        {:error, {:delivery_reconciliation_failed, reason}}
    end
  end

  defp find_message(api, client, repository, %{kind: kind, number: number}, marker)
       when kind == "issue" do
    api.find_issue_comment(client, repository, number, marker)
  end

  defp find_message(api, client, repository, %{kind: "pull", number: number}, marker),
    do: api.find_pull_review(client, repository, number, marker)

  defp find_message(
         api,
         client,
         repository,
         %{kind: "review_thread", number: number, review_root_id: root_id},
         marker
       ) do
    api.find_review_reply(client, repository, number, root_id, marker)
  end

  defp create_message(api, client, repository, request, thread, marker) do
    with {:ok, rendered} <- Renderer.render(request.document) do
      create_rendered_message(api, client, repository, thread, marker, rendered)
    end
  end

  defp create_rendered_message(api, client, repository, thread, marker, rendered) do
    body = neutralize_mentions(rendered) <> "\n\n" <> marker

    result =
      case thread do
        %{kind: "issue", number: number} ->
          api.create_issue_comment(client, repository, number, body)

        %{kind: "pull", number: number} ->
          api.create_pull_review(client, repository, number, body)

        %{kind: "review_thread", number: number, review_root_id: root_id} ->
          api.create_review_reply(client, repository, number, root_id, body)
      end

    case result do
      {:ok, message_id} -> {:ok, message_ref(thread, message_id)}
      {:error, {:delivery_rate_limited, _delay, _error} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:delivery_uncertain, reason}}
    end
  end

  defp message_ref(%{kind: "review_thread"}, id),
    do: "github:pull_request_review_comment:#{id}"

  defp message_ref(%{kind: "pull"}, id), do: "github:pull_request_review:#{id}"

  defp message_ref(_thread, id), do: "github:issue_comment:#{id}"

  defp message_identity(value) when is_binary(value) do
    case String.split(value, ":", parts: 3) do
      ["github", kind, id]
      when kind in ["issue_comment", "pull_request_review", "pull_request_review_comment"] ->
        case Integer.parse(id) do
          {id, ""} when id > 0 -> {:ok, kind, id}
          _invalid -> {:error, {:invalid_github_delivery, :message_ref}}
        end

      _invalid ->
        {:error, {:invalid_github_delivery, :message_ref}}
    end
  end

  defp message_identity(_value), do: {:error, {:invalid_github_delivery, :message_ref}}

  defp message_kind_matches_thread("pull_request_review_comment", %{kind: "review_thread"}),
    do: :ok

  defp message_kind_matches_thread("pull_request_review", %{kind: "pull"}), do: :ok

  defp message_kind_matches_thread("issue_comment", %{kind: "issue"}),
    do: :ok

  defp message_kind_matches_thread(_kind, _thread),
    do: {:error, {:invalid_github_delivery, :message_ref}}

  defp update_comment(api, client, repository, "issue_comment", comment_id, body, _thread),
    do: api.update_issue_comment(client, repository, comment_id, body)

  defp update_comment(
         api,
         client,
         repository,
         "pull_request_review",
         review_id,
         body,
         %{kind: "pull", number: number}
       ),
       do: api.update_pull_review(client, repository, number, review_id, body)

  defp update_comment(
         api,
         client,
         repository,
         "pull_request_review_comment",
         comment_id,
         body,
         _thread
       ),
       do: api.update_review_comment(client, repository, comment_id, body)

  # A future typed mention operation can reinsert host-authorized identities.
  # Unstructured model text must never page a person or an organization team.
  defp neutralize_mentions(message), do: String.replace(message, "@", "@\u200B")

  defp react(api, client, repository, %{kind: "issue_comment", id: id}, emoji_name),
    do: api.add_issue_comment_reaction(client, repository, id, emoji_name)

  defp react(
         api,
         client,
         repository,
         %{kind: "pull_request_review_comment", id: id},
         emoji_name
       ),
       do: api.add_review_comment_reaction(client, repository, id, emoji_name)

  defp client(%{bindings: bindings}, target) when is_map(bindings) do
    with {:ok, configured} <- Map.fetch(bindings, target.binding),
         %{api: api, client: client, repository_full_name: repository, repository_id: id} <-
           configured,
         true <- id == target.repository_id and repository?(repository) and valid_api?(api) do
      {:ok, api, client, repository}
    else
      _invalid -> {:error, {:github_repository_not_configured, target.binding}}
    end
  end

  defp client(_binding, target),
    do: {:error, {:github_repository_not_configured, target.binding}}

  defp repository?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)

  defp valid_api?(api) do
    callbacks = [
      find_issue_comment: 4,
      create_issue_comment: 4,
      update_issue_comment: 4,
      find_pull_review: 4,
      create_pull_review: 4,
      update_pull_review: 5,
      find_review_reply: 5,
      create_review_reply: 5,
      update_review_comment: 4,
      add_issue_comment_reaction: 4,
      add_review_comment_reaction: 4
    ]

    is_atom(api) and Code.ensure_loaded?(api) and
      Enum.all?(callbacks, fn {function, arity} -> function_exported?(api, function, arity) end)
  end
end
