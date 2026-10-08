defmodule Ryker.Slack.SourceAudits do
  @moduledoc """
  Metadata-only audit ledger for Slack list, search, and exact-source reads.

  Request text, result bodies, action tokens, and Slack credentials are never
  stored. Digests retain enough evidence to correlate an invocation without
  turning Ryker into a second Slack index.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.SourceAudit

  @fields [
    :authorized,
    :capability,
    :channel_ref,
    :complete,
    :episode_id,
    :range,
    :request,
    :requester_ref,
    :result_count,
    :source_ref,
    :tool,
    :turn_id,
    :workspace_ref
  ]
  @tools [:list_slack_channels, :search_slack, :read_slack_source]

  @spec record(map() | keyword()) :: :ok | {:error, term()}
  def record(attributes) do
    with {:ok, attributes} <- exact_attributes(attributes),
         :ok <- validate(attributes),
         changeset = SourceAudit.Changeset.insert(row(attributes)),
         {:ok, _audit} <- Repo.insert(changeset) do
      # What a run read from Slack is part of its request's record.
      Ryker.Episodes.broadcast_episode_updated(attributes.episode_id)
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, {:slack_source_audit_persistence_failed, changeset.errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp row(attributes) do
    %{
      authorized: attributes.authorized,
      capability: attributes.capability,
      channel_ref: attributes.channel_ref,
      complete: attributes.complete,
      episode_id: attributes.episode_id,
      id: Repo.generate_id(),
      range_fingerprint: CanonicalJSON.digest(attributes.range),
      request_fingerprint: CanonicalJSON.digest(attributes.request),
      requester_ref: attributes.requester_ref,
      result_count: attributes.result_count,
      source_fingerprint: digest_optional(attributes.source_ref),
      tool: attributes.tool,
      turn_id: attributes.turn_id,
      workspace_ref: attributes.workspace_ref
    }
  end

  defp exact_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> exact_attributes(),
       else: {:error, {:invalid_slack_source_audit, :fields}}
  end

  defp exact_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_slack_source_audit, :fields}}
  end

  defp exact_attributes(_attributes), do: {:error, {:invalid_slack_source_audit, :fields}}

  defp validate(attributes) do
    valid =
      Enum.all?([
        attributes.tool in @tools,
        is_boolean(attributes.authorized),
        is_boolean(attributes.complete),
        is_map(attributes.request),
        is_map(attributes.range),
        is_integer(attributes.result_count),
        attributes.result_count in 0..10_000,
        uuid?(attributes.episode_id),
        uuid?(attributes.turn_id),
        Reference.valid?(attributes.workspace_ref, 256),
        optional_reference?(attributes.channel_ref, 256),
        Reference.valid?(attributes.requester_ref, 1_024),
        Reference.valid?(attributes.capability, 128),
        optional_reference?(attributes.source_ref, 1_024)
      ])

    if valid, do: :ok, else: {:error, {:invalid_slack_source_audit, :attributes}}
  end

  defp digest_optional(nil), do: nil
  defp digest_optional(value), do: CanonicalJSON.digest(value)

  defp uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp optional_reference?(nil, _maximum), do: true
  defp optional_reference?(value, maximum), do: Reference.valid?(value, maximum)
end
