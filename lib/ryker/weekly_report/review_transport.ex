defmodule Ryker.WeeklyReport.ReviewTransport do
  @moduledoc "Erases revoked transport copies after exact remote stop proof; custody identities survive."
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work

  defp prunable?(id) do
    id
    |> CoopFleet.Command.Query.by_id()
    |> CoopFleet.Command.Query.stopped_revoked_weekly()
    |> Repo.exists?()
  end

  @doc "Only terminal commands may lose their body files; an unsettled upload still needs to ACK."
  def body_prunable?(id) do
    id
    |> CoopFleet.Command.Query.by_id()
    |> CoopFleet.Command.Query.stopped_revoked_weekly()
    |> CoopFleet.Command.Query.settled()
    |> Repo.exists?()
  end

  @doc "Compacts a late response under its command lock, retaining the original replay fingerprint."
  def compact_result(command, attributes) do
    if prunable?(command.id) do
      attributes
      |> Map.update(:result, nil, &compact_response/1)
      |> Map.update(:error, nil, &compact_error/1)
    else
      attributes
    end
  end

  @doc "Scrubs settled-owner transport copies inside the transaction recording revocation or stop proof."
  def scrub_in_transaction(review_ids) do
    session_ids =
      review_ids |> Work.Session.Query.by_weekly_review_ids() |> Repo.all() |> Enum.map(& &1.id)

    session_ids
    |> CoopFleet.Command.Query.by_session_ids()
    |> CoopFleet.Command.Query.stopped_revoked_weekly()
    |> CoopFleet.Command.Query.lock_command_for_update()
    |> Repo.all()
    |> Enum.each(fn command ->
      command
      |> CoopFleet.Command.Changeset.scrub_content(
        compact_response(command.result),
        compact_error(command.error)
      )
      |> Repo.update!()
    end)

    :ok
  end

  defp compact_response(nil), do: nil

  defp compact_response(result) do
    # The review row owns exact stop proof. A body_ref can contain a large
    # candidate: keep no copy or reference to it after that proof is durable.
    body = result["body"]

    body =
      if is_map(body) do
        Map.take(
          body,
          ~w(id session_id state revision attempt sha256 validation_attempt validation_candidate_sha256 validation_receipt)
        )
      else
        %{}
      end

    result |> Map.take(["status"]) |> Map.put("body", body)
  end

  defp compact_error(nil), do: nil
  defp compact_error(error), do: Map.take(error, ~w(code status))
end
