defmodule Responder.GitHub.Target do
  @moduledoc false

  alias Responder.Delivery.Request

  @spec parse(Request.t()) :: {:ok, map()} | {:error, term()}
  def parse(%Request{transport: "github"} = request) do
    with {:ok, binding, repository_id} <- conversation(request.conversation_ref),
         {:ok, thread} <- thread(request.thread_ref, binding),
         {:ok, source_item} <- source_item(request) do
      {:ok,
       %{
         binding: binding,
         repository_id: repository_id,
         source_item: source_item,
         thread: thread
       }}
    end
  end

  def parse(_request), do: {:error, {:invalid_github_delivery_target, :transport}}

  defp conversation(value) do
    case String.split(value, ":", parts: 4) do
      ["github", binding, "repository", repository_id] ->
        with true <- reference?(binding),
             {repository_id, ""} when repository_id > 0 <- Integer.parse(repository_id) do
          {:ok, binding, repository_id}
        else
          _invalid -> {:error, {:invalid_github_delivery_target, :conversation_ref}}
        end

      _invalid ->
        {:error, {:invalid_github_delivery_target, :conversation_ref}}
    end
  end

  defp thread(value, binding) do
    case String.split(value || "", ":") do
      ["github", ^binding, kind, number] when kind in ["issue", "pull"] ->
        case Integer.parse(number) do
          {number, ""} when number > 0 ->
            {:ok, %{kind: kind, number: number, review_root_id: nil}}

          _invalid ->
            {:error, {:invalid_github_delivery_target, :thread_ref}}
        end

      ["github", ^binding, "pull", number, "review-thread", root_id] ->
        with {number, ""} when number > 0 <- Integer.parse(number),
             {root_id, ""} when root_id > 0 <- Integer.parse(root_id) do
          {:ok, %{kind: "review_thread", number: number, review_root_id: root_id}}
        else
          _invalid -> {:error, {:invalid_github_delivery_target, :thread_ref}}
        end

      _invalid ->
        {:error, {:invalid_github_delivery_target, :thread_ref}}
    end
  end

  defp source_item(%Request{kind: :message, source_item_ref: nil}), do: {:ok, nil}

  defp source_item(%Request{kind: :reaction, source_item_ref: value}) do
    case String.split(value, ":", parts: 3) do
      ["github", kind, id]
      when kind in ["issue_comment", "pull_request_review_comment"] ->
        case Integer.parse(id) do
          {id, ""} when id > 0 ->
            {:ok, %{id: id, kind: kind}}

          _invalid ->
            {:error, {:invalid_github_delivery_target, :source_item_ref}}
        end

      _invalid ->
        {:error, {:invalid_github_delivery_target, :source_item_ref}}
    end
  end

  defp source_item(_request),
    do: {:error, {:invalid_github_delivery_target, :source_item_ref}}

  defp reference?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value)
end
