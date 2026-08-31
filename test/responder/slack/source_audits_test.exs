defmodule Responder.Slack.SourceAuditsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Slack.{SourceAudit, SourceAudits}
  alias Responder.Work.Custody

  @now ~U[2026-08-29 12:00:00.000000Z]

  test "source audits retain metadata and digests without Slack query or result content" do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: episode_id,
        episode_key: "slack-source-audit:#{episode_id}",
        native_input_id: "slack-source-audit:input:#{episode_id}",
        occurred_at: @now,
        turn_ref: "slack-source-audit:turn:#{episode_id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("slack-source-audit-worker", 60)

    assert :ok =
             SourceAudits.record(%{
               authorized: true,
               capability: "assistant.search.context",
               channel_ref: nil,
               complete: false,
               episode_id: episode_id,
               range: %{"after" => nil, "before" => nil, "cursor" => "next"},
               request: %{"query" => "secret incident phrase"},
               requester_ref: "slack:user:U123",
               result_count: 3,
               source_ref: nil,
               tool: :search_slack,
               turn_id: claim.turn.id,
               workspace_ref: "T123"
             })

    audit = Repo.one!(SourceAudit)
    assert audit.episode_id == episode_id
    assert audit.turn_id == claim.turn.id
    assert audit.requester_ref == "slack:user:U123"
    assert audit.result_count == 3
    assert audit.complete == false
    assert byte_size(audit.request_fingerprint) == 64
    assert byte_size(audit.range_fingerprint) == 64
    refute inspect(audit) =~ "secret incident phrase"
    refute Map.has_key?(Map.from_struct(audit), :result_body)
    refute Map.has_key?(Map.from_struct(audit), :action_token)
  end

  test "invalid source-audit identity is rejected before persistence" do
    assert SourceAudits.record(%{}) == {:error, {:invalid_slack_source_audit, :fields}}
    assert Repo.aggregate(SourceAudit, :count) == 0
  end
end
