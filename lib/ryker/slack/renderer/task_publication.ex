defmodule Ryker.Slack.Renderer.TaskPublication do
  @moduledoc """
  The publication section of a task card: where the draft pull request stands
  and the exact recovery controls the host authorized for this generation.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  @publication_controls ~w(publish open retry update discard)
  # Why Ryker ended a publication itself; a person's discard has none.
  @discarded_reasons [nil, "review_session_closed"]
  # What a person did to the pull request on GitHub; nil while it is open.
  @pull_request_states [nil, "closed", "merged"]

  @spec validate(map() | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(
        %{
          "automatic_fix" => automatic_fix,
          "blocked_reason" => _blocked_reason,
          "branch" => branch,
          "controls" => controls,
          "discarded_reason" => discarded_reason,
          "publication_ref" => publication_ref,
          "pull_request_number" => number,
          "pull_request_state" => pull_request_state,
          "pull_request_url" => url,
          "recovery_generation" => recovery_generation,
          "status" => status,
          "unverified" => unverified
        } = publication
      )
      when map_size(publication) == 12 and discarded_reason in @discarded_reasons and
             pull_request_state in @pull_request_states do
    with :ok <- bounded_text(status, 120),
         :ok <- optional_bounded_text(automatic_fix, 300),
         :ok <- optional_bounded_text(publication["blocked_reason"], 700),
         :ok <- optional_bounded_text(branch, 512),
         :ok <- publication_controls(controls),
         :ok <- optional_publication_reference(publication_ref),
         :ok <- optional_positive_integer(number),
         :ok <- optional_positive_integer(recovery_generation),
         :ok <- optional_bounded_text(unverified, 500),
         :ok <- optional_https_url(url) do
      publication_control_identity(
        controls,
        publication_ref,
        number,
        url,
        recovery_generation
      )
    end
  end

  def validate(_publication), do: {:error, :invalid_task_publication}

  @spec blocks(String.t(), String.t(), map() | nil) :: [map()]
  def blocks(_task_ref, _repository, nil), do: []

  def blocks(task_ref, repository, %{
        "automatic_fix" => automatic_fix,
        "blocked_reason" => blocked_reason,
        "branch" => branch,
        "controls" => controls,
        "discarded_reason" => discarded_reason,
        "publication_ref" => publication_ref,
        "pull_request_number" => number,
        "pull_request_state" => pull_request_state,
        "pull_request_url" => url,
        "recovery_generation" => recovery_generation,
        "status" => status,
        "unverified" => unverified
      }) do
    detail =
      cond do
        not (is_binary(url) and is_integer(number)) -> ""
        is_nil(pull_request_state) -> " · #{link(url, "Open draft PR ##{number}")}"
        true -> " · #{link(url, "PR ##{number}")}"
      end

    message =
      publication_message(status, controls, %{
        automatic_fix: automatic_fix,
        blocked_reason: blocked_reason,
        discarded_reason: discarded_reason,
        number: number,
        pull_request_state: pull_request_state,
        unverified: unverified
      })

    summary = section("#{message}#{detail}#{publication_branch_line(status, branch)}")

    buttons =
      Enum.map(controls, fn
        "publish" ->
          button(
            "ryker_task_publish",
            publish_label(number),
            "#{task_ref}|#{publication_ref}",
            "primary",
            publish_title(number),
            repository |> publish_confirmation(number, unverified) |> truncate(300),
            publish_label(number)
          )

        # Opening the pull request is what a published task is for (Andrew, 2026-10-03:
        # "make open pr button green").
        "open" ->
          "ryker_open_publication"
          |> url_button("Open PR", publication_ref, url)
          |> maybe_button_style("primary")

        "retry" ->
          button(
            "ryker_task_retry_publication",
            "Retry publication",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "primary",
            "Retry the failed step",
            "Retry the step that failed? The checked changes stay exactly as they are.",
            "Retry"
          )

        "update" ->
          button(
            "ryker_task_update_publication",
            "Review latest state",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            nil,
            "Check the latest changes",
            "Check the changes again as they are now? The new result replaces this one.",
            "Check again"
          )

        "discard" ->
          button(
            "ryker_task_discard_publication",
            "Discard candidate",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "danger",
            "Discard these changes",
            "Stop preparing a PR from these changes? A check still running is dropped, and the task's history is kept.",
            "Discard"
          )
      end)

    if buttons == [],
      do: [summary],
      else: [summary, actions("#{task_ref}:publication", buttons)]
  end

  # The host's own line for a fix round Ryker is running on the refusal
  # (`Ryker.Publication.FixLoop`) says what the blocked status would not.
  # A person closed or merged the pull request on GitHub, and that is the news whatever Ryker was
  # doing with it: Andrew closed draft PR #90 and this line still read "Draft PR created. Open
  # it to review the changes." (2026-10-04).
  defp publication_message(_status, _controls, %{pull_request_state: "closed"}),
    do: "The pull request was closed without merging."

  defp publication_message(_status, _controls, %{pull_request_state: "merged"}),
    do: "The pull request was merged."

  defp publication_message(_status, _controls, %{automatic_fix: fix}) when is_binary(fix),
    do: escape(fix)

  defp publication_message("discarded", _controls, facts),
    do: discarded_message(facts.discarded_reason)

  defp publication_message("blocked", controls, facts),
    do: blocked_message(controls, facts.unverified, facts.blocked_reason, facts.number)

  # A task's newer change goes to its open draft by itself (Andrew, 2026-10-01), so a
  # publication with a pull request is updating that one, never creating a draft.
  defp publication_message("publish_pending", controls, facts) do
    cond do
      "update" in controls ->
        stopped_publish_message(facts.number)

      # Someone changed the branch or pull request on GitHub; nothing can be checked again
      # against what they did, so Discard is all that is offered.
      controls == ["discard"] ->
        changed_on_github_message(facts.number)

      is_integer(facts.number) and "retry" not in controls ->
        "Updating draft PR ##{facts.number}. Waiting for GitHub to confirm."

      true ->
        publication_status_message("publish_pending", controls, facts.unverified)
    end
  end

  defp publication_message(status, controls, facts),
    do: publication_status_message(status, controls, facts.unverified)

  # A publish that stopped for good, such as a refused grant or a branch that moved, is never
  # "waiting for GitHub": it needs the changes checked again before a draft can follow. Why it
  # stopped is the card's Action needed line.
  defp stopped_publish_message(number) when is_integer(number),
    do: "The draft PR wasn't updated. Review latest state checks the changes again first."

  defp stopped_publish_message(_number),
    do: "The draft PR wasn't created. Review latest state checks the changes again first."

  defp changed_on_github_message(number) when is_integer(number),
    do: "The draft PR wasn't updated. Discard this change, or ask for it again."

  defp changed_on_github_message(_number),
    do: "The draft PR wasn't created. Discard this change, or ask for it again."

  # A draft-authorized task never rests in "reviewed": its checks passing is
  # enough for the draft the confirming person already granted. What is left
  # here is a candidate nobody granted a draft for.
  defp publication_status_message("reviewed", _controls, _unverified),
    do:
      "The changes passed their checks. I don't have a draft-PR grant for this task, so open the draft when you want one."

  defp publication_status_message("published", _controls, nil),
    do: "Draft PR created. Open it to review the changes."

  # A draft opened because a check could not run stays explicitly unverified
  # after it exists. Saying only "open it to review the changes" is how an
  # unrun gate reads as a checked change one message later. Which check, and
  # why, is the Self-review row's to say.
  defp publication_status_message("published", _controls, _unverified),
    do:
      "Draft PR created from the saved change. It isn't verified, and a draft doesn't merge or deploy anything."

  defp publication_status_message("published_ready", _controls, _unverified),
    do: "Draft PR created. Sending the publication update."

  defp publication_status_message(status, controls, _unverified) do
    cond do
      "retry" in controls ->
        "PR preparation stopped after an error. Retry the saved step below."

      status == "publish_pending" ->
        "Creating the draft PR. Waiting for GitHub to confirm."

      true ->
        "Checking the changes before creating a PR. It takes a few minutes; this card updates when the check is done."
    end
  end

  # One line says what failed and why, above the buttons that act on it
  # (Andrew, 2026-09-28: "⚠️ PR creation failed: the repository's checks
  # failed on the committed change. [buttons]"). The reason is the host's own
  # words, set only when the card's sources may be shown.
  #
  # A change whose checks could not run is a person's call, and the words say
  # which pull request it goes to: a task's newer change belongs on the draft
  # the task already opened.
  #
  # Why the checks did not verify it is said once, on the Self-review row
  # right above; this line offers the choice it leaves.
  defp blocked_message(controls, unverified, reason, number) when is_binary(unverified) do
    if "publish" in controls,
      do: unverified_offer(number) <> recheck_offer(controls),
      else: blocked_message(controls, nil, reason, number)
  end

  defp blocked_message(_controls, _unverified, reason, _number) when is_binary(reason),
    do: ":warning: *PR creation failed:* #{escape(reason)}"

  defp blocked_message(_controls, _unverified, _reason, _number),
    do: ":warning: *PR creation failed.*"

  defp unverified_offer(number) when is_integer(number),
    do:
      "I saved the newer change exactly as it is. I can add it to draft PR ##{number} marked unverified"

  defp unverified_offer(_number),
    do: "I saved the change exactly as it is. I can open it as a draft PR marked unverified"

  # Only where checking again could give another answer (`Ryker.Slack.TaskCardProjection`).
  defp recheck_offer(controls),
    do: if("update" in controls, do: ", or review the latest state again.", else: ".")

  defp publish_label(number) when is_integer(number), do: "Update draft PR"
  defp publish_label(_number), do: "Create draft PR"

  defp publish_title(number) when is_integer(number), do: "Update the draft pull request"
  defp publish_title(_number), do: "Create draft pull request"

  # A closed worker session can never be reviewed, so Ryker ends that request
  # itself; the task's next finished run is checked afresh.
  defp discarded_message("review_session_closed"),
    do:
      "I stopped preparing the PR: the worker session holding these changes closed before they could be checked, so no PR was made from them. When the task runs again, its new changes are checked then."

  defp discarded_message(nil),
    do:
      "Someone discarded these changes, so I stopped preparing their PR. The review history is saved."

  defp publish_confirmation(repository, number, unverified) do
    target =
      if is_integer(number),
        do: "Update draft PR ##{number} in #{repository} with this exact",
        else: "Open a draft pull request in #{repository} from this exact"

    case unverified do
      nil -> "#{target} reviewed change? This does not merge or deploy it."
      text -> "#{target} saved change? #{text} A draft does not merge or deploy anything."
    end
  end

  # Which branch is stuck is a fact the host holds and the card withheld, so
  # "PR creation is blocked" sent the reader to a web console this installation
  # publishes no URL for. Only the blocked state needs it: every other state
  # either links the pull request or has no branch worth naming yet.
  defp publication_branch_line("blocked", "refs/heads/" <> branch),
    do: publication_branch_line("blocked", branch)

  defp publication_branch_line("blocked", branch) when is_binary(branch) and branch != "",
    do: " · `#{escape(branch)}`"

  defp publication_branch_line(_status, _branch), do: ""

  defp publication_controls(controls) do
    if unique_subset?(controls, @publication_controls),
      do: :ok,
      else: {:error, :invalid_publication_controls}
  end

  defp publication_control_identity(
         controls,
         publication_ref,
         number,
         url,
         recovery_generation
       ) do
    valid =
      Enum.all?(controls, fn
        "publish" ->
          is_binary(publication_ref)

        "open" ->
          is_binary(publication_ref) and is_integer(number) and is_binary(url)

        action when action in ~w(retry update discard) ->
          is_binary(publication_ref) and is_integer(recovery_generation)
      end)

    if valid, do: :ok, else: {:error, :invalid_publication_controls}
  end

  defp optional_publication_reference(nil), do: :ok

  defp optional_publication_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/, value),
      do: :ok,
      else: {:error, :invalid_publication_reference}
  end
end
