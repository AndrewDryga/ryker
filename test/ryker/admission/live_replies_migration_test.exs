defmodule Ryker.Admission.LiveRepliesMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Admission.Decision
  alias Ryker.CanonicalJSON

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @before_version 20_260_926_154_500
  @live_replies_version 20_260_927_090_000
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @at ~N[2026-09-26 16:57:36.000000]

  # Routing's decision carried one `message` and one `reaction` until
  # 2026-09-27; it now carries `messages` and `reactions` (Andrew, 2026-09-26:
  # "Now both reply and add a reaction" started a 1 min 22 s work run). The
  # host reads one shape only, so every stored decision is rewritten: a
  # decision left behind in the old shape would read as a message routing sent
  # nothing for, and its stored fingerprint would no longer match it. What was
  # already sent keeps its delivery and becomes the first of its message.
  test "the migration rewrites every stored routing decision and keeps what was sent" do
    repo = start_migration_repo!()
    prefix = "live_replies_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @before_version,
        prefix: prefix,
        log: false
      )

      # A greeting routing answered, a message it reacted to before `message`
      # and `repository` existed, one it left alone before any selector
      # existed, and one whose decision retention already replaced.
      greeting =
        entry!(repo, prefix, "greeting", "quick_reply", %{
          "action" => "quick_reply",
          "episode_ref" => nil,
          "message" => "Hi! How can I help?",
          "reaction" => nil,
          "reason" => "A greeting needs a short answer, not work.",
          "relation" => "unrelated",
          "repository" => nil,
          "repository_source" => nil,
          "work_class" => nil
        })

      reacted =
        entry!(repo, prefix, "reacted", "react", %{
          "action" => "react",
          "episode_ref" => nil,
          "reaction" => %{"emoji_name" => "eyes"},
          "reason" => "Acknowledge the update.",
          "relation" => "unrelated",
          "repository_source" => nil,
          "work_class" => nil
        })

      quiet =
        entry!(repo, prefix, "quiet", "ignore", %{
          "action" => "ignore",
          "episode_ref" => nil,
          "reaction" => nil,
          "reason" => "A status note for the team.",
          "relation" => "unrelated",
          "work_class" => nil
        })

      pruned = entry!(repo, prefix, "pruned", "ignore", %{"retention" => "pruned"})

      response!(repo, prefix, greeting, "message", %{"message" => "Hi! How can I help?"})
      response!(repo, prefix, reacted, "reaction", %{"emoji_name" => "eyes"})

      assert @live_replies_version in Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @live_replies_version,
               prefix: prefix,
               log: false
             )

      assert {greeting_document, greeting_fingerprint} = decision(repo, prefix, greeting)
      assert greeting_document["messages"] == ["Hi! How can I help?"]
      assert greeting_document["reactions"] == nil
      refute Map.has_key?(greeting_document, "message")

      assert {reacted_document, reacted_fingerprint} = decision(repo, prefix, reacted)
      assert reacted_document["reactions"] == ["eyes"]
      assert reacted_document["messages"] == nil
      assert reacted_document["repository"] == nil

      assert {quiet_document, quiet_fingerprint} = decision(repo, prefix, quiet)
      assert quiet_document["repository_source"] == nil

      # Each reads in the one shape the host reads, with the choice and the
      # words it was recorded with, under the fingerprint the host takes of it.
      for {document, fingerprint} <- [
            {greeting_document, greeting_fingerprint},
            {reacted_document, reacted_fingerprint},
            {quiet_document, quiet_fingerprint}
          ] do
        assert {:ok, parsed} = Decision.parse(document)
        assert Decision.fingerprint(parsed) == fingerprint
      end

      assert decision(repo, prefix, pruned) ==
               {%{"retention" => "pruned"}, String.duplicate("d", 64)}

      # What was sent keeps its delivery reference, as the first of its message.
      assert %{rows: sent} =
               SQL.query!(
                 repo,
                 "SELECT input_id, position, delivery_ref FROM #{prefix}.delivery_routing_responses ORDER BY delivery_ref",
                 []
               )

      assert Enum.sort(Enum.map(sent, fn [_input, position, ref] -> {position, ref} end)) ==
               Enum.sort([
                 {1, "ingress-message:#{greeting}"},
                 {1, "ingress-reaction:#{reacted}"}
               ])

      # A message may now have several responses, each in its own place.
      response!(repo, prefix, greeting, "reaction", %{"emoji_name" => "wave"}, 2)

      assert_raise Postgrex.Error, ~r/delivery_routing_responses_input_position_index/, fn ->
        response!(repo, prefix, greeting, "message", %{"message" => "And another."}, 2)
      end

      # The previous release keeps one response per message and one message
      # or reaction per decision; rolling back while a message has more
      # would lose what was sent, so it is refused until they are gone.
      assert_raise Postgrex.Error, ~r/nowhere to keep them/, fn ->
        Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
      end

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.delivery_routing_responses WHERE position = 2",
        []
      )

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@live_replies_version]

      assert {previous, fingerprint} = decision(repo, prefix, greeting)
      assert previous["message"] == "Hi! How can I help?"
      assert previous["reaction"] == nil
      refute Map.has_key?(previous, "messages")
      assert fingerprint == CanonicalJSON.digest(Map.drop(previous, ["reason", "message"]))

      assert {%{"reaction" => %{"emoji_name" => "eyes"}}, _fingerprint} =
               decision(repo, prefix, reacted)
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp entry!(repo, prefix, name, action, document) do
    id = Ecto.UUID.generate()

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.ingress_inbox_entries
        (id, dedupe_key, event_fingerprint, source_kind, source_ref, source_item_ref,
         event_ref, event_kind, native_input_id, actor_kind, actor_ref,
         source_capabilities, destination_transport, destination_conversation_ref,
         destination_thread_ref, revision, occurred_at, occurred_at_source, content,
         execution_mode, status, decision_ref, decision_fingerprint, decision_action,
         decision_document, attempt_count, execution_generation, validation_generation,
         inserted_at, updated_at)
      VALUES ($1, $2, $3, 'slack', 'T1', $4, $5, 'message', $6, 'user', 'U1',
              '{"react":{"emoji_names":null}}', 'slack', 'slack:T1:C1', $4, 1, $7, 'source',
              '{"text":"hi"}', 'live', 'decided', $8, $3, $9, $10, 0, 1, 1, $7, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        "dedupe:#{name}",
        String.duplicate("d", 64),
        "1788562304.00010#{:erlang.phash2(name, 10)}",
        "event:#{name}",
        "native:#{name}",
        @at,
        "decision:#{name}",
        action,
        CanonicalJSON.encode!(document)
      ]
    )

    id
  end

  # Before the migration a response has no position; after it, one is given.
  defp response!(repo, prefix, input_id, kind, document, position \\ nil) do
    delivery_ref =
      if position,
        do: "ingress-#{kind}:#{input_id}:#{position}",
        else: "ingress-#{kind}:#{input_id}"

    {position_column, position_value} =
      if position, do: {", position", ", #{position}"}, else: {"", ""}

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.delivery_routing_responses
        (id, input_id, kind, decision_ref, delivery_ref, transport, conversation_ref,
         thread_ref, source_item_ref, document, document_fingerprint, status, attempt_count,
         retry_generation, external_receipt, external_receipt_fingerprint, delivered_at,
         inserted_at, updated_at#{position_column})
      VALUES ($1, $2, $3, 'decision', $4, 'slack', 'slack:T1:C1', '1788562304.000100',
              '1788562304.000100', $5, $6, 'delivered', 1, 0, '{}', $6, $7, $7, $7#{position_value})
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(input_id),
        kind,
        delivery_ref,
        CanonicalJSON.encode!(document),
        String.duplicate("e", 64),
        @at
      ]
    )
  end

  defp decision(repo, prefix, id) do
    %{rows: [[document, fingerprint]]} =
      SQL.query!(
        repo,
        "SELECT decision_document, decision_fingerprint FROM #{prefix}.ingress_inbox_entries WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    {Jason.decode!(document), fingerprint}
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
