defmodule Responder.ControlPlane.ConversationMemoryReadOnlyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.ControlPlane.ConversationMemory
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Knowledge, as: Fixtures
  alias Responder.Learning.Rebuilds
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    Continuity,
    ConversationKnowledge,
    ConversationObservation,
    Knowledge,
    LearningSources
  }

  test "read-only inspection shows usable knowledge and revision history without acquiring write locks" do
    # The restored Blitz inspection server rejected FOR SHARE and hid every
    # Knowledge card, although its retained source history was still readable.
    with_topics(fn fixture ->
      before = snapshot(fixture.workspace)

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION READ ONLY")
                 assert Repo.query!("SHOW transaction_read_only").rows == [["on"]]

                 for id <- [fixture.local, fixture.inherited] do
                   view = ConversationMemory.project(%{"kind" => "knowledge", "item" => id})
                   assert [%{available: true, text: text}] = view.items
                   assert text =~ "draft-ai-suggestions"
                   assert [%{version: 1}] = view.history

                   assert {:ok, %{topic_id: ^id, version: 1, available?: true}} =
                            Rebuilds.preview(id, %{page: 1, q: ""})
                 end

                 :ok
               end)

      assert snapshot(fixture.workspace) == before
    end)
  end

  for {change, local, inherited} <- [
        {:public, true, true},
        {:private, true, false},
        {:external, true, false},
        {:left, true, false},
        {:absent, true, false},
        {:deleted, false, false}
      ] do
    test "inspection preserves local and inherited eligibility when destination becomes #{change}" do
      with_topics(fn fixture ->
        change_membership(fixture.workspace, "CTARGET", unquote(change))
        assert available?(fixture.local) == unquote(local)
        assert available?(fixture.inherited) == unquote(inherited)
      end)
    end
  end

  for change <- [:private, :external, :left, :absent, :deleted] do
    test "inspection excludes inherited knowledge after source becomes #{change}" do
      with_topics(fn fixture ->
        change_membership(fixture.workspace, "CSOURCE", unquote(change))
        assert available?(fixture.local)
        refute available?(fixture.inherited)
      end)
    end
  end

  for {before, after_change, inherited} <- [
        {:public, :private, false},
        {:public, :deleted, false},
        {:private, :public, true}
      ] do
    test "availability statement uses current destination membership after #{before} to #{after_change}" do
      with_topics(fn fixture ->
        change_membership(fixture.workspace, "CTARGET", unquote(before))
        {:ok, scope} = Continuity.destination_context(fixture.target, nil)
        query = Knowledge.availability_query(scope, [fixture.local, fixture.inherited])
        change_membership(fixture.workspace, "CTARGET", unquote(after_change))
        ids = Repo.all(query)
        assert fixture.inherited in ids == unquote(inherited)
        assert fixture.local in ids == (unquote(after_change) != :deleted)
      end)
    end
  end

  test "inspection still excludes an edited or removed inherited source" do
    with_topics(fn fixture ->
      Fixtures.revoke!(fixture.source)
      assert available?(fixture.local)
      refute available?(fixture.inherited)
    end)
  end

  test "a deleted colon-bearing channel suffix is interpreted as the exact destination" do
    with_topics(fn fixture ->
      destination = destination(fixture.workspace, "CTARGET:SUFFIX")
      joined!(fixture.workspace, "CTARGET:SUFFIX")
      {_, document} = Fixtures.learn!(destination)
      id = String.replace_prefix(document["source_ref"], "knowledge:", "")
      assert available?(id)
      change_membership(fixture.workspace, "CTARGET:SUFFIX", :deleted)
      refute available?(id)
    end)
  end

  test "direct-message inspection does not acquire a channel membership fence" do
    with_topics(fn fixture ->
      joined!(fixture.workspace, "DPRIVATE")
      {_, document} = Fixtures.learn!(destination(fixture.workspace, "DPRIVATE"))
      change_membership(fixture.workspace, "DPRIVATE", :deleted)
      id = String.replace_prefix(document["source_ref"], "knowledge:", "")
      assert available?(id)
    end)
  end

  test "non-Slack local knowledge is available in a read-only transaction" do
    with_topics(fn fixture ->
      destination = %Episode{
        destination_transport: "github",
        destination_conversation_ref: "github:#{fixture.workspace}:issues:91"
      }

      {_, document} = Fixtures.learn!(destination)
      id = String.replace_prefix(document["source_ref"], "knowledge:", "")

      assert {:ok, true} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION READ ONLY")
                 available?(id)
               end)
    end)
  end

  test "availability cannot label a healthy topic from another displayed group" do
    with_topics(fn fixture ->
      {_, other_repository} = Fixtures.learn!(fixture.target, "different-repository")
      other_id = String.replace_prefix(other_repository["source_ref"], "knowledge:", "")

      source =
        Repo.get_by!(ConversationKnowledge,
          conversation_ref: fixture.source.destination_conversation_ref
        )

      {:ok, scope} = Continuity.destination_context(fixture.target, nil)

      ids =
        Repo.all(Knowledge.availability_query(scope, [fixture.local, source.id, other_id]))

      assert ids == [fixture.local]
      assert available?(other_id)
      assert available?(source.id)
    end)
  end

  test "an expired inherited receipt disables recall without erasing its readable history" do
    with_topics(fn fixture ->
      previous = Application.get_env(:responder, :retention)
      Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3600})

      try do
        copied = Repo.get!(ConversationKnowledge, fixture.inherited)
        expired = DateTime.add(DateTime.utc_now(), -3601) |> DateTime.to_iso8601()

        # Inject age into the normalized inherited receipt, not its owner pointer.
        for source <-
              Repo.all(
                from(s in Responder.State.KnowledgeSource,
                  where: s.knowledge_id == ^copied.id
                )
              ),
            source.receipt["conversation_ref"] == fixture.source.destination_conversation_ref do
          receipt = Map.put(source.receipt, "retained_at", expired)

          Repo.update!(
            Ecto.Changeset.change(source,
              receipt: receipt,
              receipt_fingerprint: Responder.CanonicalJSON.digest(receipt),
              retained_at: DateTime.from_iso8601(expired) |> elem(1)
            )
          )
        end

        view = ConversationMemory.project(%{"kind" => "knowledge", "item" => copied.id})
        assert [%{available: false, text: text, expires_at: expires_at}] = view.items
        assert text =~ "draft-ai-suggestions"
        assert expires_at != nil
        assert [%{version: 1}] = view.history
        assert available?(fixture.local)
      after
        if previous,
          do: Application.put_env(:responder, :retention, previous),
          else: Application.delete_env(:responder, :retention)
      end
    end)
  end

  defp with_topics(fun) do
    Sandbox.unboxed_run(Repo, fn ->
      workspace = "TINSPECT#{System.unique_integer([:positive])}"

      try do
        joined!(workspace, "CSOURCE")
        joined!(workspace, "CTARGET")
        {source, source_document} = Fixtures.learn!(destination(workspace, "CSOURCE"))
        target = destination(workspace, "CTARGET")
        {entry, local_document} = Fixtures.learn!(target)

        inherited_document =
          Enum.find(
            Knowledge.context(target, nil),
            &(&1["source_ref"] == source_document["source_ref"])
          )

        assert inherited_document["can_update"] == false

        dependencies =
          LearningSources.merge([
            LearningSources.for_entry(entry),
            LearningSources.document_sources(inherited_document)
          ])

        assert length(dependencies) == 2

        # The prose is the retained draft-ai-suggestions fixture. Only the
        # additional topic identity and copied-source topology are host setup.
        proposal =
          source_document
          |> Map.take(~w(title summary topics))
          |> Map.merge(%{
            "topic_key" => "copied-draft-ai-suggestions",
            "target_ref" => nil,
            "anchors" => [],
            "expected_version" => 0
          })

        assert {:ok, :ok} =
                 Repo.transaction(fn ->
                   Knowledge.record_sources_in_transaction(
                     [entry],
                     proposal,
                     [inherited_document],
                     %{
                       result_ref: "recorded-source-topology",
                       source_dependencies: dependencies,
                       omissions: []
                     }
                   )
                 end)

        copied =
          Repo.get_by!(ConversationKnowledge,
            conversation_ref: target.destination_conversation_ref,
            topic_key: "copied-draft-ai-suggestions"
          )

        assert LearningSources.expand(copied.source_dependencies) ==
                 LearningSources.expand(dependencies)

        fun.(%{
          workspace: workspace,
          source: source,
          target: target,
          local: String.replace_prefix(local_document["source_ref"], "knowledge:", ""),
          inherited: copied.id
        })
      after
        scopes = ["slack:#{workspace}", "github:#{workspace}"]
        Repo.delete_all(from(k in ConversationKnowledge, where: k.workspace_ref in ^scopes))
        Repo.delete_all(from(o in ConversationObservation, where: o.workspace_ref in ^scopes))
        Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == ^workspace))
      end
    end)
  end

  defp available?(id) do
    assert [%{available: available}] =
             ConversationMemory.project(%{"kind" => "knowledge", "item" => id}).items

    available
  end

  defp snapshot(workspace) do
    scope = "slack:#{workspace}"

    {
      Repo.all(
        from(k in ConversationKnowledge, where: k.workspace_ref == ^scope, order_by: k.id)
      ),
      Repo.all(
        from(o in ConversationObservation, where: o.workspace_ref == ^scope, order_by: o.id)
      ),
      Repo.all(from(m in ChannelMembership, where: m.workspace_ref == ^workspace, order_by: m.id))
    }
  end

  defp destination(workspace, channel),
    do: %Episode{
      destination_transport: "slack",
      destination_conversation_ref: "slack:#{workspace}:#{channel}"
    }

  defp joined!(workspace, channel) do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: workspace,
      channel_ref: channel,
      private: false,
      external_shared: false,
      generation: 1,
      status: :joined,
      joined_at: DateTime.utc_now()
    })
  end

  defp change_membership(workspace, channel, change) do
    query =
      from(m in ChannelMembership,
        where: m.workspace_ref == ^workspace and m.channel_ref == ^channel
      )

    case change do
      :absent ->
        Repo.delete_all(query)

      :public ->
        Repo.update_all(query, set: [status: :joined, private: false, external_shared: false])

      :private ->
        Repo.update_all(query, set: [private: true])

      :external ->
        Repo.update_all(query, set: [external_shared: true])

      :left ->
        Repo.update_all(query, set: [status: :left, left_at: DateTime.utc_now()])

      :deleted ->
        Repo.update_all(query, set: [status: :deleted, deleted_at: DateTime.utc_now()])
    end
  end
end
