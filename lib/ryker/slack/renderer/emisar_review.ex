defmodule Ryker.Slack.Renderer.EmisarReview do
  @moduledoc """
  The governed-review card: the Emisar approvals one reply asked for, posted
  from the durable records and repainted from the authoritative poll.

  Approvals that share their action, reasons and command are one card: the
  shared part once, then each runner's status and buttons below a divider.
  Production asked for the same inspection on two instances (2026-10-08), the
  two cards repeated each other, and each approval's update replaced the
  other's card.
  """
  import Ryker.Slack.Renderer.Blocks
  alias Ryker.Emisar
  alias Ryker.Wording

  # Slack takes at most 50 blocks a message; approvals past that are counted.
  @maximum_blocks 50
  @maximum_field_characters 2_000

  @spec render([map()]) :: {:ok, map()} | {:error, term()}
  def render([_first | _rest] = statuses) do
    prepared = Enum.map(statuses, &Emisar.ApprovalStatus.prepare/1)

    if Enum.all?(prepared, &match?({:ok, _status}, &1)) do
      cards =
        Enum.map(prepared, fn {:ok, status} ->
          {status, Emisar.ApprovalStatus.review_summary(status),
           "emisar-approval:#{status["request_id"]}"}
        end)

      {:ok, %{"blocks" => cards_blocks(cards), "text" => cards_text(cards)}}
    else
      {:error, {:invalid_slack_render, :emisar_approval_statuses}}
    end
  end

  def render(_statuses), do: {:error, {:invalid_slack_render, :emisar_approval_statuses}}

  @doc """
  The first cards of governed reviews, posted from their durable records
  (`{ref, payload}`, in order) before the monitor has polled anything.
  """
  @spec approval_blocks([{String.t(), map()}]) :: [map()]
  def approval_blocks(approvals) do
    approvals
    |> Enum.map(fn {ref, payload} ->
      status = Map.merge(payload, %{"remote_error" => nil, "review" => nil, "run_url" => nil})
      {status, Emisar.ApprovalStatus.review_summary(status), ref}
    end)
    |> cards_blocks()
  end

  defp cards_blocks(cards) do
    {blocks, left} =
      cards
      |> Enum.chunk_by(&shared_key/1)
      |> Enum.reduce({[], 0}, fn group, {blocks, left} ->
        rendered =
          if blocks == [], do: group_blocks(group), else: [divider() | group_blocks(group)]

        if left == 0 and length(blocks) + length(rendered) < @maximum_blocks,
          do: {blocks ++ rendered, 0},
          else: {blocks, left + length(group)}
      end)

    if left == 0,
      do: blocks,
      else: blocks ++ [context(Wording.count(left, "more approval") <> " in Emisar.")]
  end

  # Approvals that ask for the same thing in the same words; runners differ. A
  # command is the same command whether Emisar previews it or reports it run,
  # so one runner finishing first does not split the card.
  defp shared_key({status, _review, _ref}) do
    facts = status["review"] || %{}

    {status["action_id"], status["pack_ref"], cut(facts, "reason"), cut(facts, "evidence"),
     cut(facts, "expected"), facts["argument_count"],
     facts["command"] && Map.take(facts["command"], ~w(text truncated))}
  end

  defp group_blocks([{status, review, ref}]), do: review_blocks(status, review, ref)

  defp group_blocks([{status, _review, _ref} | _more] = group) do
    kinds =
      group |> Enum.map(fn {status, _review, _ref} -> command_kind(status) end) |> Enum.uniq()

    shared_blocks(status, kinds) ++ Enum.flat_map(group, &runner_row/1)
  end

  defp command_kind(status), do: get_in(status, ["review", "command", "kind"])

  # One runner of a shared card: its runner and status side by side, then its
  # buttons. A status too long for a field keeps the whole width.
  defp runner_row({status, review, ref}) do
    runner = "*Runner*\n`#{escape(status["runner_ref"])}`"
    %{"text" => %{"text" => state}} = state_block = status_block(status, review)

    row =
      if String.length(state) <= @maximum_field_characters,
        do: [%{"fields" => [mrkdwn(runner), mrkdwn(state)], "type" => "section"}],
        else: [section(runner), state_block]

    [divider() | row] ++ [review_actions(status, ref)]
  end

  defp mrkdwn(text), do: %{"text" => text, "type" => "mrkdwn"}
  defp divider, do: %{"type" => "divider"}

  defp cards_text([{status, review, _ref}]), do: review_text(status, review)

  defp cards_text([{status, _review, _ref} | _more] = cards) do
    case Enum.uniq_by(cards, &shared_key/1) do
      [_one] ->
        "Emisar review · #{escape(status["action_id"])} · #{length(cards)} runners"

      _several ->
        "Emisar review · " <> Wording.count(length(cards), "approval")
    end
  end

  # One governed-review card, whether it is being posted from the durable
  # record or repainted from the authoritative poll. Both render the same card,
  # so the operator watches one message change rather than reading two designs.
  # The immutable refs stay one authorized link away: this card leads with the
  # human decision, not with machine provenance.
  defp review_blocks(status, review, block_ref) do
    shared_blocks(status, [command_kind(status)]) ++
      [
        section("*Runner*\n`#{escape(status["runner_ref"])}`"),
        status_block(status, review),
        review_actions(status, block_ref)
      ]
  end

  # `kinds` are the command kinds of every runner the part is shared by.
  defp shared_blocks(status, kinds) do
    review_facts = status["review"] || %{}

    Enum.reject(
      [
        section("*Emisar review*"),
        rationale("Reason", cut(review_facts, "reason")),
        rationale("Evidence", cut(review_facts, "evidence")),
        rationale("Expected outcome", cut(review_facts, "expected"))
      ] ++ command_blocks(status, review_facts, kinds),
      &is_nil/1
    )
  end

  # Emisar marks a text it cut to fit; the card says so instead of passing it off as whole.
  defp cut(facts, key) do
    case {facts[key], facts[key <> "_truncated"]} do
      {text, true} when is_binary(text) -> text <> " …"
      {text, _whole} -> text
    end
  end

  defp rationale(_heading, nil), do: nil
  defp rationale(heading, text), do: section("*#{heading}*\n#{escape(text)}")

  # `Command to run` is said only for a trusted, secret-masked preview Emisar
  # stands behind, and `Executed command` only for a real run receipt; a command
  # some runners ran and others have not is just the command. With neither, the
  # card names the action it is reviewing and says how many arguments stayed in
  # Emisar — it never reconstructs a command line.
  defp command_blocks(_status, %{"command" => %{} = command}, kinds) do
    heading =
      case kinds do
        ["executed"] -> "Executed command"
        ["preview"] -> "Command to run"
        _mixed -> "Command"
      end

    [
      section("*#{heading}*"),
      code_block(command["text"]),
      if(command["truncated"], do: context("Command truncated · the full command is in Emisar."))
    ]
  end

  defp command_blocks(status, review_facts, _kinds) do
    [
      section("*Action*"),
      code_block(status["action_id"]),
      argument_note(review_facts["argument_count"])
    ]
  end

  defp argument_note(count) when is_integer(count) and count > 0,
    do: context(Wording.count(count, "argument") <> " in Emisar.")

  defp argument_note(_count), do: nil

  # Current status first, one blank line, then the decisions oldest first — one
  # event per line, with a terminal decision left where it happened.
  defp status_block(status, nil),
    do: section("*Status*\n#{escape(Emisar.ApprovalStatus.label(status["status"]))}")

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
            "Open run",
            status["run_id"],
            status["run_url"]
          )
      ]
      |> Enum.reject(&is_nil/1)

    actions(block_ref, buttons)
  end

  defp pending_review?(%{"review" => %{"status" => status}}), do: status == "pending"
  defp pending_review?(%{"status" => status}), do: status == "pending_approval"

  defp review_text(status, nil) do
    "Emisar review · #{escape(status["action_id"])} · #{Emisar.ApprovalStatus.label(status["status"])}"
  end

  defp review_text(status, %{summary: summary}),
    do: "Emisar review · #{escape(status["action_id"])} · #{escape(summary)}"
end
