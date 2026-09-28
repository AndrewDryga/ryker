defmodule Ryker.Repo.Migrations.RecordLocalRoutingQuotes do
  use Ecto.Migration

  # A person forgetting a message erases every local routing comparison of a
  # prompt that quoted it, compared ones with the local model's answer
  # included (found in review, 2026-09-28). A comparison now records what its
  # prompt quotes, as a routing example does: its message's identity, the
  # message and topic keys, and the conversations they come from
  # (`Ryker.RoutingExamples.quoted_keys/1`), so forgetting finds them by an
  # index rather than by reading every comparison's context.
  #
  # Each comparison kept before gets the same keys from the context its
  # message froze. The keys are worked out here as routing works them out
  # today, so this migration means the same thing whenever it runs.
  #
  # Rolling back keeps every comparison and forgets only the keys.

  alias Ryker.CanonicalJSON

  @batch 500

  def up do
    alter table(:local_routing_comparisons) do
      add(:source_identity, :text)
      add(:message_keys, {:array, :text}, null: false, default: [])
      add(:conversation_refs, {:array, :text}, null: false, default: [])
    end

    execute(fn -> record_quotes() end)

    execute(
      "ALTER TABLE #{qualified("local_routing_comparisons")} ALTER COLUMN source_identity SET NOT NULL"
    )

    create(
      constraint(:local_routing_comparisons, :local_routing_comparison_quotes_valid,
        check: "source_identity ~ '^[0-9a-f]{64}$'"
      )
    )

    create(index(:local_routing_comparisons, [:source_identity]))
    create(index(:local_routing_comparisons, [:message_keys], using: :gin))
    create(index(:local_routing_comparisons, [:conversation_refs], using: :gin))
  end

  def down do
    drop(index(:local_routing_comparisons, [:conversation_refs]))
    drop(index(:local_routing_comparisons, [:message_keys]))
    drop(index(:local_routing_comparisons, [:source_identity]))
    drop(constraint(:local_routing_comparisons, :local_routing_comparison_quotes_valid))

    alter table(:local_routing_comparisons) do
      remove(:conversation_refs)
      remove(:message_keys)
      remove(:source_identity)
    end
  end

  # Batch by batch in id order, each comparison's keys taken from its
  # message's frozen routing context.
  defp record_quotes(after_id \\ nil) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT comparison.id, input.source_kind, input.source_ref, input.native_input_id,
               input.source_item_ref, input.destination_conversation_ref, input.admission_context
        FROM #{qualified("local_routing_comparisons")} AS comparison
        JOIN #{qualified("ingress_inbox_entries")} AS input ON input.id = comparison.input_id
        WHERE $1::uuid IS NULL OR comparison.id > $1::uuid
        ORDER BY comparison.id
        LIMIT #{@batch}
        """,
        [after_id],
        log: false
      )

    quotes =
      for [id, kind, source, native, item, conversation, context] <- rows do
        quoted = quoted(conversation, item || native, decoded(context))

        [
          id,
          CanonicalJSON.digest(%{
            "source_kind" => kind,
            "source_ref" => source,
            "native_input_id" => native
          }),
          CanonicalJSON.encode!(quoted.keys),
          CanonicalJSON.encode!(quoted.conversations)
        ]
      end

    if quotes != [] do
      repo().query!(
        """
        UPDATE #{qualified("local_routing_comparisons")} AS comparison
        SET source_identity = quoted.identity,
            message_keys = ARRAY(SELECT jsonb_array_elements_text(quoted.keys::jsonb)),
            conversation_refs = ARRAY(SELECT jsonb_array_elements_text(quoted.conversations::jsonb))
        FROM unnest($1::uuid[], $2::text[], $3::text[], $4::text[])
          AS quoted(id, identity, keys, conversations)
        WHERE comparison.id = quoted.id
        """,
        quotes |> Enum.zip() |> Enum.map(&Tuple.to_list/1),
        log: false
      )
    end

    if length(rows) == @batch, do: record_quotes(rows |> List.last() |> hd())
  end

  defp decoded(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = context} -> context
      _other -> %{}
    end
  end

  defp decoded(_none), do: %{}

  # The message itself; the thread root, the earlier messages and the current
  # one of its conversation; learned observations, with the conversation each
  # came from; and learned topics.
  defp quoted(conversation, message_ref, context) do
    history =
      if is_map(context["conversation_context"]), do: context["conversation_context"], else: %{}

    messages =
      [{conversation, message_ref}] ++
        for(
          %{"source_message_ref" => ref} when is_binary(ref) <-
            [history["root"], history["current"] | list(history["messages"])],
          do: {conversation, ref}
        ) ++
        for(
          %{"conversation_ref" => observed_in, "source_message_ref" => ref}
          when is_binary(observed_in) and is_binary(ref) <-
            list(context["conversation_observations"]),
          do: {observed_in, ref}
        )

    topics =
      for %{"source_ref" => "knowledge:" <> id} = topic <- list(context["conversation_knowledge"]),
          do: {id, topic["conversation_ref"]}

    %{
      keys:
        (Enum.map(messages, fn {c, m} ->
           CanonicalJSON.digest(%{"conversation_ref" => c, "message_ref" => m})
         end) ++ Enum.map(topics, &CanonicalJSON.digest(%{"knowledge" => elem(&1, 0)})))
        |> Enum.uniq()
        |> Enum.sort(),
      conversations:
        (Enum.map(messages, &elem(&1, 0)) ++ for({_id, c} when is_binary(c) <- topics, do: c))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp list(values) when is_list(values), do: values
  defp list(_absent), do: []

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
