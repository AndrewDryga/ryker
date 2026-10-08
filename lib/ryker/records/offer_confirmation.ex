defmodule Ryker.Records.OfferConfirmation do
  @moduledoc """
  What a person's click on an offer card carries, checked before anything is
  locked: who confirmed (`actor_ref`), the click (`confirmation_ref`), the
  offer (`record_ref`), when (`occurred_at`, an exact UTC time) and the card's
  message (`target`). Facts, behaviors and automation changes each kept their
  own copy of these checks (2026-10-04 review); each still names a refusal in
  its own words, `{tag, field}`.
  """
  alias Ryker.Reference
  alias Ryker.UTCDateTime

  @fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]

  @type t :: %{
          actor_ref: String.t(),
          confirmation_ref: String.t(),
          occurred_at: DateTime.t(),
          record_ref: String.t(),
          target: %{
            conversation_ref: String.t(),
            message_ref: String.t(),
            thread_ref: String.t() | nil,
            transport: String.t()
          }
        }

  @doc """
  The confirmation `attributes` describe, or `{:error, {tag, field}}` naming
  the first field that is missing, extra or malformed (`:fields` for the set).
  """
  @spec new(keyword() | map(), atom()) :: {:ok, t()} | {:error, {atom(), atom()}}
  def new(attributes, tag) when is_atom(tag) do
    with {:ok, attributes} <- fields(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- occurred_at(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      {:ok, %{attributes | occurred_at: occurred_at, target: target}}
    else
      {:error, field} -> {:error, {tag, field}}
    end
  end

  @doc "When something an offer keeps for `expires_in` from `confirmed_at` ends."
  @spec expires_at(DateTime.t(), String.t()) :: DateTime.t()
  def expires_at(confirmed_at, "7d"), do: DateTime.add(confirmed_at, 7, :day)
  def expires_at(confirmed_at, "30d"), do: DateTime.add(confirmed_at, 30, :day)
  def expires_at(confirmed_at, "90d"), do: DateTime.add(confirmed_at, 90, :day)
  def expires_at(confirmed_at, "365d"), do: DateTime.add(confirmed_at, 365, :day)

  defp fields(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> fields(),
       else: {:error, :fields}
  end

  defp fields(%{} = attributes) do
    if Enum.sort(Map.keys(attributes)) == @fields,
      do: {:ok, attributes},
      else: {:error, :fields}
  end

  defp fields(_attributes), do: {:error, :fields}

  defp occurred_at(value) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, :occurred_at}
    end
  end

  defp target(%{} = target) do
    with true <- Enum.sort(Map.keys(target)) == @target_fields,
         :ok <- reference(target.transport, :transport),
         :ok <- reference(target.conversation_ref, :conversation_ref),
         :ok <- optional_reference(target.thread_ref, :thread_ref),
         :ok <- reference(target.message_ref, :message_ref) do
      {:ok, target}
    else
      false -> {:error, :target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target(_target), do: {:error, :target}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field), do: if(Reference.valid?(value), do: :ok, else: {:error, field})
end
