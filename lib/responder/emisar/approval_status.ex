defmodule Responder.Emisar.ApprovalStatus do
  @moduledoc """
  Host-owned projection of one exact governed run onto its original message.

  It contains no approval control. The authoritative approval URL is retained
  only as a link, while the run status, the failure detail and the review
  receipt come from the exact read-only `wait_for_run` observation.

  The field set is an exact allowlist on both sides of that boundary: a receipt
  Emisar grows is refused here until this list and Emisar's published example
  move together, which fails one test rather than every governed-review card.
  """

  alias Responder.CanonicalJSON
  alias Responder.Emisar.{Approval, Review, RunState}

  @fields ~w(action_id approval_url expires_at operation_id pack_ref remote_error request_id review run_id run_url runner_ref status)
  # One receipt carries the rationale, the command, and up to twenty recorded
  # decisions with their own notes; the old 16 KiB ceiling was sized for a
  # document that carried none of them.
  @maximum_document_bytes 64 * 1_024

  @spec new(Approval.t(), RunState.t()) :: {:ok, map()} | {:error, term()}
  def new(%Approval{} = approval, %RunState{} = state) do
    prepare(%{
      "action_id" => approval.action_id,
      "approval_url" => approval.approval_url,
      "expires_at" => DateTime.to_iso8601(approval.expires_at),
      "operation_id" => approval.operation_id,
      "pack_ref" => approval.pack_ref,
      "remote_error" => state.error_message,
      "request_id" => approval.request_id,
      "review" => state.review,
      "run_id" => approval.run_id,
      "run_url" => state.run_url,
      "runner_ref" => approval.runner_ref,
      "status" => state.status
    })
  end

  def new(_approval, _state), do: {:error, {:invalid_emisar_approval_status, :document}}

  @spec prepare(term()) :: {:ok, map()} | {:error, term()}
  def prepare(%{} = document) do
    with true <- Enum.sort(Map.keys(document)) == @fields,
         :ok <- reference(document["action_id"], 200),
         :ok <- https_url(document["approval_url"]),
         :ok <- timestamp(document["expires_at"]),
         :ok <- reference(document["operation_id"], 200),
         :ok <- reference(document["pack_ref"], 300),
         :ok <- optional_text(document["remote_error"], 1_000),
         :ok <- reference(document["request_id"], 80),
         {:ok, _review} <- Review.prepare(document["review"]),
         :ok <- exact_hold(document),
         :ok <- reference(document["run_id"], 200),
         :ok <- optional_https_url(document["run_url"]),
         :ok <- reference(document["runner_ref"], 300),
         true <- document["status"] in RunState.statuses(),
         :ok <- canonical(document) do
      {:ok, document}
    else
      _invalid -> {:error, {:invalid_emisar_approval_status, :document}}
    end
  end

  def prepare(_document), do: {:error, {:invalid_emisar_approval_status, :document}}

  @doc """
  The card's review status line and decision history, or `nil` for a run no
  human reviewed.

  A poll that could not refresh the review says so; it never becomes a denial,
  an expiry, or a silent "nobody voted".
  """
  @spec review_summary(map()) :: %{summary: String.t(), history: [String.t()]} | nil
  def review_summary(%{"review" => %{} = review}), do: Review.summary(review)

  def review_summary(%{"remote_error" => error}) when is_binary(error) do
    %{summary: "⚠ Couldn't refresh review status. Check Emisar for the latest.", history: []}
  end

  # A hold whose receipt has not arrived yet is waiting, not undecided: the card
  # says so without inventing a tally nobody reported.
  def review_summary(%{"status" => "pending_approval"}),
    do: %{summary: "◷ Waiting for review.", history: []}

  def review_summary(%{}), do: nil

  @spec label(String.t()) :: String.t()
  def label("pending_approval"), do: "Approval required"
  # These four were one label, so the card rendered identically whether the
  # action was still queued here, handed over, executing on the runner, or being
  # cancelled — and an operator watching a production restart could not see that
  # their cancellation was in flight. Each says where the action actually is.
  def label("pending"), do: "Queued, not sent yet"
  def label("sent"), do: "Sent to the runner"
  def label("running"), do: "Running on the runner"
  def label("cancelling"), do: "Cancelling"
  def label("success"), do: "Succeeded"
  def label("denied"), do: "Denied in Emisar"
  def label("refused"), do: "Refused by policy"
  def label("cancelled"), do: "Cancelled"
  def label("timed_out"), do: "Timed out"
  def label("validation_failed"), do: "Validation failed"
  def label("unknown_action"), do: "Unknown action"
  def label(status) when status in ~w(failed error), do: "Failed"

  # A receipt for another hold is not this card's evidence, however well formed.
  defp exact_hold(%{"review" => nil}), do: :ok

  defp exact_hold(%{"request_id" => request_id, "review" => %{"request_id" => request_id}}),
    do: :ok

  defp exact_hold(_document), do: {:error, :review}

  defp canonical(document) do
    case CanonicalJSON.validate(document, max_bytes: @maximum_document_bytes) do
      :ok -> :ok
      {:error, _reason} -> {:error, :canonical}
    end
  end

  defp https_url(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        reference(value, 2_048)

      _invalid ->
        {:error, :url}
    end
  end

  defp https_url(_value), do: {:error, :url}

  defp optional_https_url(nil), do: :ok
  defp optional_https_url(value), do: https_url(value)

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> :ok
      _invalid -> {:error, :timestamp}
    end
  end

  defp timestamp(_value), do: {:error, :timestamp}

  defp optional_text(nil, _maximum), do: :ok
  defp optional_text(value, maximum), do: reference(value, maximum)

  defp reference(value, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, :reference}
  end
end
