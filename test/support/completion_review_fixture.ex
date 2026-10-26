defmodule Ryker.Fixtures.CompletionReview do
  @moduledoc false
  alias Ryker.Repo
  alias Ryker.TestSupport.FakeWorkCoopAPI
  alias Ryker.Work.{CompletionReview, Final, Turn}

  # Deliberately a host boundary double, not a claimed production model result.
  def judgment(state) do
    decision =
      case state do
        "waiting_for_input" -> "request_input"
        "waiting_for_event" -> "wait_for_event"
        _complete -> "complete"
      end

    Jason.encode!(%{
      "decision" => decision,
      "dismiss_wait_refs" => [],
      "reason" => "The test's configured review decision.",
      "requirements" => [
        %{
          "requirement" => "The test's requested outcome",
          "status" => "satisfied",
          "evidence" => "The configured boundary double accepts this candidate."
        }
      ],
      "actions" =>
        if(decision == "complete",
          do: [],
          else: [
            %{
              "requirement" => "Await the recorded dependency",
              "action" => "Use the recorded wait or input request.",
              "basis" => "The test's configured dependency."
            }
          ]
        )
    })
  end

  # Initialize disclosure custody while the fixture native transcript is fresh.
  def attest!(claim) do
    :ok = Ryker.Knowledge.KnowledgeSnapshot.expose(claim, [])
    claim
  end

  def approve!(claim, candidate) do
    {:ok, final} = Final.parse(candidate)

    {:ok, api} =
      FakeWorkCoopAPI.start_link([judgment(candidate["outcome"]["state"])], review_only: true)

    claim = %{
      claim
      | turn: Repo.get!(Turn, claim.turn.id),
        session: Ryker.Fixtures.WorkerJob.pin!(claim.session)
    }

    :ok =
      CompletionReview.review(claim, final, %{
        api: FakeWorkCoopAPI,
        client: api,
        lease_seconds: 300
      })
  end
end
