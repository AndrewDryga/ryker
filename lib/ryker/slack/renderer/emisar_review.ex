defmodule Ryker.Slack.Renderer.EmisarReview do
  @moduledoc """
  The governed-review card: one Emisar approval message that is posted from
  the durable record and repainted from the authoritative poll.
  """

  import Ryker.Slack.Renderer.Blocks

  alias Ryker.Emisar.ApprovalStatus

  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(status) do
    case ApprovalStatus.prepare(status) do
      {:ok, status} ->
        review = ApprovalStatus.review_summary(status)

        {:ok,
         %{
           "blocks" =>
             review_blocks(
               status,
               review,
               "emisar-approval:#{status["request_id"]}"
             ),
           "text" => review_text(status, review)
         }}

      _invalid ->
        {:error, {:invalid_slack_render, :emisar_approval_status}}
    end
  end

  @doc """
  The first card of a governed review, posted from the durable record before
  the monitor has polled anything.
  """
  @spec approval_blocks(String.t(), map()) :: [map()]
  def approval_blocks(ref, payload) do
    status = Map.merge(payload, %{"remote_error" => nil, "review" => nil, "run_url" => nil})

    review_blocks(status, ApprovalStatus.review_summary(status), ref)
  end

  # One governed-review message, whether it is being posted from the durable
  # record or repainted from the authoritative poll. Both render the same card,
  # so the operator watches one message change rather than reading two designs.
  defp review_blocks(status, review, block_ref) do
    review_facts = status["review"] || %{}

    rationale = [
      section("*Emisar review*"),
      rationale("Reason", review_facts["reason"]),
      rationale("Evidence", review_facts["evidence"]),
      rationale("Expected outcome", review_facts["expected"])
    ]

    # The immutable refs stay one authorized link away: this card leads with the
    # human decision, not with machine provenance.
    identity = [
      section("*Runner*\n`#{escape(status["runner_ref"])}`"),
      status_block(status, review),
      review_actions(status, block_ref)
    ]

    Enum.reject(
      rationale ++ command_blocks(status, review_facts) ++ identity,
      &is_nil/1
    )
  end

  defp rationale(_heading, nil), do: nil
  defp rationale(heading, text), do: section("*#{heading}*\n#{escape(text)}")

  # `Command to run` is said only for a trusted, secret-masked preview Emisar
  # stands behind, and `Executed command` only for a real run receipt. With
  # neither, the card names the action it is reviewing and says how many
  # arguments stayed in Emisar — it never reconstructs a command line.
  defp command_blocks(_status, %{"command" => %{} = command}) do
    heading = if command["kind"] == "executed", do: "Executed command", else: "Command to run"

    [
      section("*#{heading}*"),
      code_block(command["text"]),
      if(command["truncated"], do: context("Command truncated · the full command is in Emisar."))
    ]
  end

  defp command_blocks(status, review_facts) do
    [
      section("*Action*"),
      code_block(status["action_id"]),
      argument_note(review_facts["argument_count"])
    ]
  end

  defp argument_note(count) when is_integer(count) and count > 0,
    do: context("#{count} #{plural(count, "argument", "arguments")} in Emisar.")

  defp argument_note(_count), do: nil

  # Current status first, one blank line, then the decisions oldest first — one
  # event per line, with a terminal decision left where it happened.
  defp status_block(status, nil),
    do: section("*Status*\n#{escape(ApprovalStatus.label(status["status"]))}")

  defp status_block(_status, %{summary: summary, history: history}) do
    section(
      "*Status*\n" <>
        Enum.join([escape(summary) | history_lines(history)], "\n")
    )
  end

  defp history_lines([]), do: []
  defp history_lines(history), do: ["" | Enum.map(history, &escape/1)]

  # Review happens in Emisar, so its link is the card's primary action while a
  # decision is still open; afterwards the same message links the decided record.
  defp review_actions(status, block_ref) do
    open? = pending_review?(status)

    buttons =
      [
        status["approval_url"] &&
          url_button(
            "ryker_open_emisar_approval",
            if(open?, do: "Review in Emisar", else: "Open in Emisar"),
            status["request_id"],
            status["approval_url"]
          )
          |> maybe_button_style(if(open?, do: "primary")),
        status["run_url"] &&
          url_button(
            "ryker_open_emisar_run",
            "Open exact run",
            status["run_id"],
            status["run_url"]
          )
      ]
      |> Enum.reject(&is_nil/1)

    actions(block_ref, buttons)
  end

  defp pending_review?(%{"review" => %{"status" => status}}), do: status == "pending"
  defp pending_review?(%{"status" => status}), do: status == "pending_approval"

  defp review_text(status, nil),
    do:
      "Emisar review · #{escape(status["action_id"])} · #{ApprovalStatus.label(status["status"])}"

  defp review_text(status, %{summary: summary}),
    do: "Emisar review · #{escape(status["action_id"])} · #{escape(summary)}"
end
