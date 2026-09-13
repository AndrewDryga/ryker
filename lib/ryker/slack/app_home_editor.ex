defmodule Ryker.Slack.AppHomeEditor do
  @moduledoc """
  Opens actor-filtered App Home editors without exposing another actor's state.

  The modal carries only the pending review reference. Submission re-reads the
  same review and applies the edit through memory's transactional review fence.
  """

  alias Ryker.State.Memories

  @callback_id "ryker_home_edit_memory_review"

  @spec open_memory_review(module(), term(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def open_memory_review(api, client, review_ref, trigger_ref, actor_ref, workspace_ref) do
    with true <- is_atom(api) and function_exported?(api, :open_view, 3),
         {:ok, review} <- Memories.fetch_home_review(review_ref, workspace_ref, actor_ref),
         {:ok, view} <- memory_review_view(review_ref, review),
         :ok <- api.open_view(client, trigger_ref, view) do
      :ok
    else
      false -> {:error, {:invalid_app_home_editor, :api}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_app_home_editor, :view}}
    end
  end

  @spec callback_id() :: String.t()
  def callback_id, do: @callback_id

  @doc false
  @spec memory_review_view(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def memory_review_view(review_ref, review) do
    with "memory-review:" <> _ <- review_ref,
         {:ok, entry} <- editable_entry(review) do
      {:ok, view(review_ref, entry)}
    else
      _invalid -> {:error, :memory_review_cannot_edit}
    end
  end

  defp editable_entry(%{"kind" => "stale", "entries" => [entry]}) when is_map(entry) do
    case {entry["subject"], entry["value"]} do
      {subject, value} when is_binary(subject) and is_binary(value) ->
        if bounded_input?(subject, 120) and bounded_input?(value, 4_000),
          do: {:ok, entry},
          else: {:error, :memory_review_cannot_edit}

      _invalid ->
        {:error, :memory_review_cannot_edit}
    end
  end

  defp editable_entry(_review), do: {:error, :memory_review_cannot_edit}

  defp bounded_input?(value, maximum) do
    length = value |> String.trim() |> String.length()
    length in 1..maximum
  end

  defp view(review_ref, entry) do
    %{
      "blocks" => [
        input("memory_subject", "subject", "Subject", entry["subject"], 120),
        input("memory_value", "value", "Stored guidance", entry["value"], 4_000)
      ],
      "callback_id" => @callback_id,
      "close" => plain("Cancel"),
      "private_metadata" => Jason.encode!(%{"review_ref" => review_ref}),
      "submit" => plain("Save edit"),
      "title" => plain("Edit memory"),
      "type" => "modal"
    }
  end

  defp input(block_id, action_id, label, initial_value, maximum) do
    %{
      "block_id" => block_id,
      "element" => %{
        "action_id" => action_id,
        "initial_value" => initial_value,
        "max_length" => maximum,
        "min_length" => 1,
        "type" => "plain_text_input"
      },
      "label" => plain(label),
      "type" => "input"
    }
  end

  defp plain(text), do: %{"emoji" => true, "text" => text, "type" => "plain_text"}
end
