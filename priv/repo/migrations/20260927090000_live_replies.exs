defmodule Ryker.Repo.Migrations.LiveReplies do
  use Ecto.Migration

  # Andrew, 2026-09-26: "Now both reply and add a reaction" started a 1 min
  # 22 s work run, because routing could answer by itself with one message or
  # one emoji, never both. Routing's quick answer is now one to three
  # messages sent in order plus up to three emoji on the person's message,
  # and a reaction alone up to three emoji; the Work model may post a short
  # update into its own conversation while it works.
  #
  # - What routing sends by itself is an ordered list per message: each
  #   routing response has its position, delivered after every earlier one.
  #   Every response already sent was the only one for its message, so it
  #   keeps its delivery reference and becomes position 1.
  # - Every stored routing decision is rewritten into the one shape the host
  #   reads: `message` becomes `messages` (a list, or null), `reaction`
  #   becomes `reactions` (a list of emoji names, or null), and the selectors
  #   a decision recorded before they existed never chose are written as null.
  #   Its fingerprint is taken again from the rewritten document, as the host
  #   takes it, so a stored decision always matches its own fingerprint.
  # - `post_slack_update` is the platform action a Work update is delivered by.
  #
  # Rolling back refuses while anything the previous release cannot hold
  # exists: several responses for one message, a decision with more than one
  # message or emoji, or a Work update.

  alias Ryker.CanonicalJSON

  @previous_tools ~w(set_slack_reaction post_slack_message set_github_reaction)
  @tools @previous_tools ++ ~w(post_slack_update)
  @nullable ~w(episode_ref repository repository_source work_class)
  @batch 500

  def up do
    alter table(:delivery_routing_responses) do
      add(:position, :integer, null: false, default: 1)
    end

    execute(
      "ALTER TABLE #{qualified("delivery_routing_responses")} ALTER COLUMN position DROP DEFAULT"
    )

    create(
      constraint(:delivery_routing_responses, :delivery_routing_response_position_valid,
        check: "position BETWEEN 1 AND 6"
      )
    )

    drop(
      index(:delivery_routing_responses, [:input_id],
        name: :delivery_routing_responses_input_id_index
      )
    )

    create(
      unique_index(:delivery_routing_responses, [:input_id, :position],
        name: :delivery_routing_responses_input_position_index
      )
    )

    replace_platform_action_tools(@tools)
    execute(fn -> rewrite_decisions(&current_shape/1, ["reason", "messages"]) end)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("delivery_routing_responses")} WHERE position > 1)
        OR EXISTS (
          SELECT 1 FROM #{qualified("ingress_inbox_entries")}
          WHERE decision_document IS NOT NULL
            AND decision_document::jsonb ? 'action'
            AND (#{longer_than_one("messages")} OR #{longer_than_one("reactions")})
        )
        OR EXISTS (
          SELECT 1 FROM #{qualified("platform_actions")} WHERE tool = 'post_slack_update'
        )
      THEN
        RAISE EXCEPTION 'routing sent several messages or emoji for one message, or Work posted an update while it worked; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    execute(fn -> rewrite_decisions(&previous_shape/1, ["reason", "message"]) end)
    replace_platform_action_tools(@previous_tools)

    drop(
      index(:delivery_routing_responses, [:input_id, :position],
        name: :delivery_routing_responses_input_position_index
      )
    )

    create(
      unique_index(:delivery_routing_responses, [:input_id],
        name: :delivery_routing_responses_input_id_index
      )
    )

    drop(constraint(:delivery_routing_responses, :delivery_routing_response_position_valid))

    alter table(:delivery_routing_responses) do
      remove(:position)
    end
  end

  # A decision stored in any earlier shape, in the one the host reads now.
  # A document already in it is left as it is.
  defp current_shape(document) do
    messages =
      case document do
        %{"messages" => messages} -> messages
        %{"message" => message} when is_binary(message) -> [message]
        _none -> nil
      end

    reactions =
      case document do
        %{"reactions" => reactions} -> reactions
        %{"reaction" => %{"emoji_name" => emoji}} when is_binary(emoji) -> [emoji]
        _none -> nil
      end

    document
    |> Map.drop(["message", "reaction"])
    |> Map.merge(%{"messages" => messages, "reactions" => reactions})
    |> then(fn reshaped -> Enum.reduce(@nullable, reshaped, &Map.put_new(&2, &1, nil)) end)
  end

  # The previous release reads one message and one reaction; `down` refused
  # before anything longer could reach here.
  defp previous_shape(document) do
    message =
      case document["messages"] do
        [message] -> message
        _none -> nil
      end

    reaction =
      case document["reactions"] do
        [emoji] -> %{"emoji_name" => emoji}
        _none -> nil
      end

    document
    |> Map.drop(["messages", "reactions"])
    |> Map.merge(%{"message" => message, "reaction" => reaction})
  end

  # Batch by batch in id order, each changed document written back with the
  # fingerprint the host takes of it: the document without its prose.
  defp rewrite_decisions(reshape, prose, after_id \\ nil) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, decision_document FROM #{qualified("ingress_inbox_entries")}
        WHERE decision_document IS NOT NULL AND decision_document::jsonb ? 'action'
          AND ($1::uuid IS NULL OR id > $1::uuid)
        ORDER BY id
        LIMIT #{@batch}
        """,
        [after_id],
        log: false
      )

    changed =
      for [id, text] <- rows,
          document = Jason.decode!(text),
          reshaped = reshape.(document),
          reshaped != document do
        [id, CanonicalJSON.encode!(reshaped), CanonicalJSON.digest(Map.drop(reshaped, prose))]
      end

    if changed != [] do
      repo().query!(
        """
        UPDATE #{qualified("ingress_inbox_entries")} AS entry
        SET decision_document = rewritten.document,
            decision_fingerprint = rewritten.fingerprint
        FROM unnest($1::uuid[], $2::text[], $3::text[]) AS rewritten(id, document, fingerprint)
        WHERE entry.id = rewritten.id
        """,
        changed |> Enum.zip() |> Enum.map(&Tuple.to_list/1),
        log: false
      )
    end

    if length(rows) == @batch,
      do: rewrite_decisions(reshape, prose, rows |> List.last() |> hd())
  end

  defp longer_than_one(field) do
    """
    CASE WHEN jsonb_typeof(decision_document::jsonb -> '#{field}') = 'array'
      THEN jsonb_array_length(decision_document::jsonb -> '#{field}') ELSE 0 END > 1
    """
  end

  # The same identity check as before, naming every tool a platform action
  # may come from; an update is always a message.
  defp replace_platform_action_tools(tools) do
    drop(constraint(:platform_actions, :platform_actions_identity_valid))

    create(
      constraint(:platform_actions, :platform_actions_identity_valid,
        check: """
        char_length(action_ref) BETWEEN 1 AND 256
        AND char_length(host_slot) BETWEEN 1 AND 256
        AND tool IN (#{Enum.map_join(tools, ", ", &"'#{&1}'")})
        AND (tool <> 'post_slack_update' OR kind = 'message')
        AND kind IN ('message', 'reaction')
        AND char_length(transport) BETWEEN 1 AND 1024
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND (thread_ref IS NULL OR char_length(thread_ref) BETWEEN 1 AND 1024)
        AND (source_item_ref IS NULL OR char_length(source_item_ref) BETWEEN 1 AND 1024)
        AND char_length(intent_fingerprint) = 64
        AND attempt_count >= 0
        AND retry_generation >= 0
        """
      )
    )
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
