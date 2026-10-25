defmodule Ryker.Behaviors.GuidanceSnapshotTest do
  use Ryker.DataCase, async: false
  alias Ryker.Behaviors
  alias Ryker.Fixtures.Corrections
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.StateTools.FixedTools

  # Deleting a correction removed its host obligation but still sent its old
  # words to the worker. Every disclosure and retained transcript needs the fence.
  for withdrawal <- [:deleted, :disabled, :expired] do
    test "#{withdrawal} guidance invalidates saved automatic context and its native transcript" do
      {saved, claim, _document} = guidance!()
      assert KnowledgeSnapshot.expose_submission(claim) == :ok
      withdraw!(saved, unquote(withdrawal))

      assert KnowledgeSnapshot.authorize_submission(
               claim.episode,
               claim.session,
               claim.turn.submission
             ) ==
               {:error, :work_knowledge_context_stale}

      assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
               {:error, :work_knowledge_context_stale}
    end
  end

  test "withdrawn guidance cannot be disclosed through an explicit memory read" do
    {saved, claim, document} = guidance!()
    withdraw!(saved, :deleted)
    assert KnowledgeSnapshot.expose(claim, [document]) == {:error, :work_knowledge_context_stale}
  end

  test "a frozen guidance reference cannot authorize changed wording" do
    {_saved, claim, document} = guidance!()
    changed = Map.put(document, "text", "An instruction the operator never saved.")

    submission =
      put_in(claim.turn.submission, ["context", "operator_context", "guidance"], [changed])

    assert KnowledgeSnapshot.authorize_submission(claim.episode, claim.session, submission) ==
             {:error, :work_knowledge_context_stale}
  end

  test "unchanged guidance remains available for automatic and explicit disclosure" do
    {_saved, claim, document} = guidance!()

    assert KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session,
             claim.turn.submission
           ) == :ok

    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    assert KnowledgeSnapshot.expose(claim, [document]) == :ok
    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) == :ok
  end

  test "unproven older native custody cannot become an empty guidance history" do
    {_saved, claim, _document} = guidance!()

    claim.session
    |> Ecto.Changeset.change(
      coop_session_id: "legacy-guidance:#{claim.session.id}",
      guidance_exposures: nil
    )
    |> Repo.update!()

    assert KnowledgeSnapshot.authorize_session(claim.episode, claim.session) ==
             {:error, :work_knowledge_context_stale}
  end

  test "guidance disclosed automatically keeps that role after an explicit reread" do
    {saved, claim, document} = guidance!()
    assert KnowledgeSnapshot.expose_submission(claim) == :ok
    before_session = Repo.get!(Ryker.Work.Session, claim.session.id)
    assert KnowledgeSnapshot.expose(claim, [document]) == :ok
    after_session = Repo.get!(Ryker.Work.Session, claim.session.id)
    receipt = after_session.guidance_exposures[saved["behavior_ref"]]
    assert receipt["automatic"] == true
    assert receipt == before_session.guidance_exposures[saved["behavior_ref"]]
    refute inspect(receipt) =~ document["text"]
  end

  defp guidance! do
    correction = Corrections.correction!()

    assert {:ok, saved} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _ -> true end
             )

    claim = Corrections.later!(correction)
    [document] = claim.turn.submission["context"]["operator_context"]["guidance"]
    {saved, claim, document}
  end

  defp withdraw!(saved, :expired) do
    saved["behavior_ref"]
    |> Behaviors.Behavior.Query.by_ref()
    |> Repo.fetch!()
    |> Ecto.Changeset.change(
      confirmed_at: DateTime.add(Repo.now!(), -120, :second),
      expires_at: DateTime.add(Repo.now!(), -1, :second)
    )
    |> Repo.update!()
  end

  defp withdraw!(saved, status), do: Behaviors.set_status(saved["behavior_ref"], status)
end
