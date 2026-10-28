defmodule Ryker.WeeklyReport.ReviewEvidence do
  @moduledoc "Bounded, already-public evidence and its forgetting provenance for a weekly review."
  alias Ryker.{CanonicalJSON, ConversationRef, Episodes, InspectionRedactor}
  alias Ryker.{Repo, RoutingExamples}
  alias Ryker.{Settings, Slack, Work}
  alias Ryker.WeeklyReport.Review

  @maximum_entries 80
  @maximum_bytes 80_000

  @doc "Freezes delivered public answers; the caller holds the shared forgetting lock."
  def gather(week, destination) do
    with {:ok, workspace, _channel} <- ConversationRef.parse_slack(destination),
         {:ok, %Settings.Slack{workspace_ref: ^workspace, workspace_url: origin}} <-
           Repo.fetch(Settings.Slack.Query.all()) do
      conversations = public_conversations(workspace)

      rows =
        Repo.all(
          Review.Query.delivered_evidence(week.from, week.to, conversations, @maximum_entries + 1)
        )

      secrets = InspectionRedactor.current_secrets()

      initial = %{
        items: [],
        bytes: 0,
        omitted: 0,
        turn_ids: [],
        identities: [],
        keys: [],
        conversations: []
      }

      rows
      |> Enum.reduce(initial, &keep(&1, &2, origin, secrets))
      |> Map.put(:more_available, length(rows) > @maximum_entries)
    else
      _unavailable ->
        %{
          items: [],
          bytes: 0,
          omitted: 0,
          more_available: false,
          turn_ids: [],
          identities: [],
          keys: [],
          conversations: []
        }
    end
  end

  defp keep(row, evidence, origin, secrets) do
    with {:ok, receipt} <- Work.DeliveryReceipt.prepare(row.receipt),
         {:ok, _workspace, channel} <- ConversationRef.parse_slack(receipt["conversation_ref"]),
         url when is_binary(url) <-
           Slack.Permalink.archive_url(
             origin,
             channel,
             receipt["message_ref"],
             receipt["thread_ref"]
           ),
         text when is_binary(text) and byte_size(text) > 0 <- row.message,
         {:ok, episode} <- Repo.fetch(Episodes.Episode.Query.by_id(row.episode_id)) do
      turn = %Work.Turn{id: row.turn_id, inserted_at: row.inserted_at}
      dependencies = Work.SourceDependencies.read(episode, turn)
      text = InspectionRedactor.redact(text, secrets)

      item = %{
        "id" => row.turn_id,
        "text" => text,
        "at" => DateTime.to_iso8601(row.delivered_at),
        "url" => url,
        "conversation_ref" => receipt["conversation_ref"]
      }

      bytes = byte_size(CanonicalJSON.encode!(item))

      reply_key = RoutingExamples.message_key(receipt["conversation_ref"], receipt["message_ref"])
      identities = Enum.uniq(dependencies.source_identities ++ evidence.identities)
      keys = Enum.uniq([reply_key | dependencies.message_keys] ++ evidence.keys)

      conversations =
        Enum.uniq(
          [receipt["conversation_ref"] | dependencies.conversation_refs] ++ evidence.conversations
        )

      provenance_bytes = byte_size(CanonicalJSON.encode!([identities, keys, conversations]))

      if length(conversations) > @maximum_entries or provenance_bytes > @maximum_bytes or
           not dependencies.complete? or dependencies.forgotten? or
           RoutingExamples.message_revoked?(receipt["conversation_ref"], receipt["message_ref"]) or
           evidence.bytes + bytes > @maximum_bytes or
           length(evidence.items) >= @maximum_entries do
        %{evidence | omitted: evidence.omitted + 1}
      else
        %{
          evidence
          | items: evidence.items ++ [item],
            bytes: evidence.bytes + bytes,
            turn_ids: [row.turn_id | evidence.turn_ids],
            identities: identities,
            keys: keys,
            conversations: conversations
        }
      end
    else
      _unsafe_or_missing -> %{evidence | omitted: evidence.omitted + 1}
    end
  end

  @doc "Whether every cited source still belongs to a joined public channel in the destination workspace."
  def publishable?(manifest, destination) do
    with {:ok, workspace, channel} <- ConversationRef.parse_slack(destination),
         {:ok, %{status: :joined, external_shared: false}} <-
           Repo.fetch(Slack.ChannelMembership.Query.by_channel(workspace, channel)),
         %{"evidence" => items} when is_list(items) <- manifest do
      public = public_conversations(workspace)
      Enum.all?(items, &(&1["conversation_ref"] in public))
    else
      _invalid -> false
    end
  end

  defp public_conversations(workspace),
    do: Repo.all(Slack.ChannelMembership.Query.public_conversation_refs("slack:" <> workspace))
end
