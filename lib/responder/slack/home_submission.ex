defmodule Responder.Slack.HomeSubmission do
  @moduledoc false

  alias Responder.Slack.AppHomeEditor

  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @enforce_keys [
    :action,
    :actor_ref,
    :event_ref,
    :occurred_at,
    :replacement,
    :resource_ref,
    :workspace_ref
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          action: :edit_memory_review,
          actor_ref: String.t(),
          event_ref: String.t(),
          occurred_at: DateTime.t(),
          replacement: map(),
          resource_ref: String.t(),
          workspace_ref: String.t()
        }

  @spec from_socket(map(), String.t(), DateTime.t()) ::
          {:ok, t()} | {:error, %{String.t() => String.t()}} | :ignore
  def from_socket(
        %{
          "envelope_id" => envelope_ref,
          "payload" => %{
            "team" => %{"id" => workspace_ref},
            "type" => "view_submission",
            "user" => %{"id" => actor_ref},
            "view" => %{
              "callback_id" => callback_id,
              "private_metadata" => metadata,
              "state" => %{"values" => values},
              "type" => "modal"
            }
          },
          "type" => "interactive"
        },
        workspace_ref,
        %DateTime{} = occurred_at
      ) do
    with true <- callback_id == AppHomeEditor.callback_id(),
         {:ok, "memory-review:" <> _ = review_ref} <- metadata(metadata),
         {:ok, subject, value} <- input_values(values),
         true <- Enum.all?([envelope_ref, actor_ref, workspace_ref, review_ref], &reference?/1),
         true <- utc?(occurred_at) do
      {:ok,
       %__MODULE__{
         action: :edit_memory_review,
         actor_ref: actor_ref,
         event_ref: "interaction:#{envelope_ref}",
         occurred_at: normalize_datetime(occurred_at),
         replacement: %{"subject" => subject, "value" => value},
         resource_ref: review_ref,
         workspace_ref: workspace_ref
       }}
    else
      {:error, %{} = errors} -> {:error, errors}
      _invalid -> :ignore
    end
  end

  def from_socket(_envelope, _workspace_ref, _occurred_at), do: :ignore

  defp metadata(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case Jason.decode(value) do
      {:ok, %{"review_ref" => review_ref} = decoded} when map_size(decoded) == 1 ->
        {:ok, review_ref}

      _invalid ->
        :error
    end
  end

  defp metadata(_value), do: :error

  defp input_values(values) when is_map(values) do
    if Map.keys(values) |> Enum.sort() == ["memory_subject", "memory_value"] do
      with {:ok, subject} <-
             input_value(
               values,
               "memory_subject",
               "subject",
               120,
               "Enter a non-empty subject of at most 120 characters."
             ),
           {:ok, value} <-
             input_value(
               values,
               "memory_value",
               "value",
               4_000,
               "Enter non-empty guidance of at most 4000 characters."
             ) do
        {:ok, subject, value}
      end
    else
      :error
    end
  end

  defp input_values(_values), do: :error

  defp input_value(values, block_id, action_id, maximum, error_message) do
    case get_in(values, [block_id, action_id]) do
      %{"type" => "plain_text_input", "value" => value} = input
      when map_size(input) == 2 and is_binary(value) ->
        value = String.trim(value)

        if String.length(value) in 1..maximum,
          do: {:ok, value},
          else: {:error, %{block_id => error_message}}

      _invalid ->
        {:error, %{block_id => error_message}}
    end
  end

  defp reference?(value), do: is_binary(value) and Regex.match?(@reference, value)

  defp utc?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp normalize_datetime(%DateTime{microsecond: {microsecond, _precision}} = value),
    do: %{value | microsecond: {microsecond, 6}}
end
