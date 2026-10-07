defmodule Ryker.ControlPlane.EpisodeTrace.Input do
  @moduledoc """
  "What came in": the kernel's lifecycle events tied back to the inputs that
  caused them, how evidence was gathered across conversations, and the link to
  the source message.
  """
  import Ryker.ControlPlane.EpisodeTrace.Step
  alias Ryker.ControlPlane.ConsolePeople
  alias Ryker.Episodes.{Episode, Origins}
  alias Ryker.Episodes.Words
  alias Ryker.GitHub.Input, as: GitHubInput
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Slack.Names
  alias Ryker.StateTools.TaskTools

  @doc """
  The episode's admitted inputs, oldest first: the one that started it and the
  newest 200. The oldest 200 left a long request's timeline stopping long
  before the request did (2026-10-04 review).
  """
  @spec rows(Ecto.UUID.t()) :: [Entry.t()]
  def rows(episode_id) do
    in_episode = Entry.Query.by_episode_id(episode_id)

    first =
      in_episode
      |> Entry.Query.ordered_by_occurred_at()
      |> Entry.Query.limit_to(1)
      |> Repo.one()

    newest =
      in_episode
      |> Entry.Query.ordered_by_occurred_at_desc()
      |> Entry.Query.limit_to(200)
      |> Repo.all()
      |> Enum.reverse()

    if is_nil(first) or Enum.any?(newest, &(&1.id == first.id)),
      do: newest,
      else: [first | newest]
  end

  @doc """
  The kernel event identities that name an input, mapped to that input.

  A turn records its selection with the kernel's own input references, so the
  projection needs the kernel's mapping from those references back to inputs.
  Nothing else can resolve them: matching on the closest recorded time is the
  guess this whole grouping exists to stop making.
  """
  def input_refs(events, inputs) do
    for event <- events,
        input = event_input(event, inputs),
        into: %{},
        do: {event.dedupe_key, input.id}
  end

  @doc "Inputs by every reference a kernel event or turn can carry for them."
  def inputs_by_ref(rows) do
    rows
    |> Enum.flat_map(&[{&1.dedupe_key, &1}, {"ingress-turn:#{&1.id}", &1}])
    |> Map.new()
  end

  @doc "When the first input arrived, which can precede the episode itself."
  def first_received_at(episode) do
    received_at =
      episode.id
      |> Entry.Query.by_episode_id()
      |> Entry.Query.select_earliest_insert()
      |> Repo.one()

    case received_at do
      %DateTime{} = at ->
        if DateTime.compare(at, episode.inserted_at) == :lt, do: at, else: episode.inserted_at

      nil ->
        episode.inserted_at
    end
  end

  defp event_input(event, inputs) do
    # Kernel command identity hashes and ingress delivery hashes have different
    # contracts. Admission records the exact ingress identity in its turn ref.
    Map.get(inputs, get_in(event.payload || %{}, ["turn_ref"])) ||
      Map.get(inputs, event.dedupe_key)
  end

  @doc """
  The inputs the kernel admitted that no inbox row holds, each as the message
  it is, from its admitted payload: a task someone approved, a comment or a
  review on the task's pull request, a schedule's run, a wait whose time came.
  The timeline said only "Message added to this request." for each (Andrew,
  2026-09-29: "maybe show those added messages? otherwise it's not clear what
  is happening during task setup at all").

  A task's own request opens the task, so it is not a new message of it
  (`boundary: false`); every other one starts one, numbered with the inbox's
  messages in the order they came (`id` and `dedupe_key`, which a turn's
  selection names).
  """
  def admitted(events, inputs) do
    for event <- events,
        event.kind == :input_admitted,
        is_nil(event_input(event, inputs)),
        message = admitted_message(event) do
      %{
        id: "kernel-input:" <> event.dedupe_key,
        dedupe_key: event.dedupe_key,
        occurred_at: event.occurred_at,
        boundary: message.boundary,
        message:
          Map.merge(message, %{
            id: "kernel-input:" <> event.dedupe_key,
            at: event.occurred_at,
            owner:
              if(message.boundary,
                do: {:input, "kernel-input:" <> event.dedupe_key},
                else: :episode
              )
          })
      }
    end
  end

  @doc "The admitted messages that start a message of their own, as causality counts inputs."
  def admitted_inputs(admitted) do
    for(
      %{boundary: true} = input <- admitted,
      do: Map.take(input, [:id, :dedupe_key, :occurred_at])
    )
  end

  @doc "A turn's selection names an admitted input by the kernel's reference to it."
  def admitted_refs(admitted),
    do: for(%{boundary: true} = input <- admitted, into: %{}, do: {input.dedupe_key, input.id})

  defp admitted_message(%{payload: %{"payload" => %{"task" => %{} = task} = payload} = envelope}) do
    {actor, person} = approver(envelope, payload["confirmed_by"])

    %{
      boundary: false,
      title: "Task approved",
      actor: actor,
      person: person,
      text:
        [
          present_text(task["title"]) && "**#{task["title"]}**",
          present_text(TaskTools.request(task["prompt"]))
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
        |> bounded_text(),
      available: true,
      transport: "task",
      source: nil
    }
  end

  defp admitted_message(%{
         payload: %{"payload" => %{"source" => %{"kind" => "github"}} = payload}
       }) do
    github = get_in(payload, ["content", "payload"]) || %{}
    number = get_in(github, ["issue", "number"]) || get_in(github, ["pull_request", "number"])
    issue? = is_map(github["issue"]) and is_nil(get_in(github, ["issue", "pull_request"]))

    pull =
      cond do
        not is_integer(number) -> " the pull request"
        issue? -> " issue ##{number}"
        true -> " PR ##{number}"
      end

    %{
      boundary: true,
      title: github_title(github, pull),
      actor: get_in(github, ["sender", "login"]) || "GitHub user",
      person: nil,
      text: github_text(payload["content"], github),
      available: true,
      transport: "github",
      source: github_source(github)
    }
  end

  defp admitted_message(%{
         payload: %{"payload" => %{"content" => %{"kind" => "scheduled_task"} = content}}
       }) do
    schedule = content["schedule"] || %{}

    %{
      boundary: true,
      title: "Scheduled run",
      actor: "Schedule",
      person: nil,
      text:
        [
          present_text(schedule["title"]) && "**#{schedule["title"]}**",
          present_text(schedule["task"])
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
        |> bounded_text(),
      available: true,
      transport: "schedule",
      source: nil
    }
  end

  defp admitted_message(%{payload: %{"payload" => %{"content" => %{"kind" => "timer_due"}}}}) do
    %{
      boundary: true,
      title: "Wait ended",
      actor: "Ryker",
      person: nil,
      text: "The time Ryker was waiting for came, so the work continues.",
      available: true,
      transport: "system",
      source: nil
    }
  end

  defp admitted_message(_event), do: nil

  # A comment on the pull request, one on a line of a file, or a review.
  defp github_title(%{"review" => %{}}, pull), do: "Review of" <> pull

  defp github_title(%{"comment" => %{"path" => path}}, pull) when is_binary(path),
    do: "Comment on #{path} in" <> pull

  defp github_title(%{"comment" => %{}}, pull), do: "Comment on" <> pull
  defp github_title(_github, pull), do: "Update on" <> pull

  # What they wrote; a review without a word says what the review was.
  defp github_text(content, github) do
    case present_text(GitHubInput.body(content)) do
      nil -> review_words(get_in(github, ["review", "state"]))
      body -> bounded_text(body)
    end
  end

  defp review_words("approved"), do: "Approved the change."
  defp review_words("changes_requested"), do: "Asked for changes."
  defp review_words("commented"), do: "Left a review with comments on the change."
  defp review_words(_state), do: "Left no words."

  defp github_source(github) do
    url =
      get_in(github, ["comment", "html_url"]) || get_in(github, ["review", "html_url"]) ||
        get_in(github, ["issue", "html_url"]) || get_in(github, ["pull_request", "html_url"])

    if is_binary(url) and String.starts_with?(url, "https://github.com/"),
      do: %{href: url, label: "Open in GitHub"}
  end

  # Who approved a task, named the way the page names them where they approved
  # it: every approval read "Slack user", one given in Chat too (2026-10-04
  # review).
  defp approver(envelope, confirmed_by) do
    case ConsolePeople.person(confirmed_by) do
      %{name: name} -> {name, nil}
      nil -> {"Slack user", slack_person(envelope, confirmed_by)}
    end
  end

  defp slack_person(%{"destination" => %{"conversation_ref" => "slack:" <> rest}}, actor)
       when is_binary(actor) do
    case String.split(rest, ":") do
      [workspace | _channel] -> Names.person(workspace, actor)
      _other -> nil
    end
  end

  defp slack_person(_payload, _actor), do: nil

  defp present_text(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: String.trim(text)
  end

  defp present_text(_text), do: nil

  defp bounded_text(text),
    do: InspectionRedactor.artifact(text, max_bytes: 12_000).text

  @doc "One step per durable kernel event, owned by the input that caused it."
  def kernel_steps(events, inputs, admitted \\ []) do
    shown = MapSet.new(admitted, & &1.dedupe_key)

    events
    |> Enum.reject(&(&1.kind == :input_admitted and MapSet.member?(shown, &1.dedupe_key)))
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      input = event_input(event, inputs)

      step(
        "kernel-#{event.sequence || index}",
        kernel_band(event.kind),
        event.occurred_at,
        %{
          actor: "Ryker",
          input_id: input && input.id,
          owner: if(input, do: {:input, input.id}, else: :episode),
          delivery_ref: get_in(event.payload || %{}, ["expected_delivery_ref"]),
          result_ref: get_in(event.payload || %{}, ["result_ref"]),
          # The source card owns input identity, message metadata and retained
          # bodies. Repeating those facts on every durable transition made the
          # timeline look like it contained new evidence when it did not.
          details: [],
          stage: kernel_stage(event.kind),
          # The title says what happened; a badge would only repeat the
          # kernel's own name for it.
          state: nil,
          summary: summary(event.kind, event.payload, input),
          title: title(event.kind, input),
          tone: kernel_tone(event.kind)
        }
      )
    end)
  end

  defp kernel_band(kind)
       when kind in [:input_admitted, :input_wait_started, :event_wait_started, :wait_resumed],
       do: :input

  defp kernel_band(:owner_transferred), do: :ready
  defp kernel_band(:result_accepted), do: :answer
  defp kernel_band(_kind), do: :outcome

  defp kernel_stage(:input_admitted), do: "Input"

  defp kernel_stage(kind) when kind in [:input_wait_started, :event_wait_started, :wait_resumed],
    do: "Wait"

  defp kernel_stage(:owner_transferred), do: "Custody"
  defp kernel_stage(:result_accepted), do: "Result"
  defp kernel_stage(:delivery_confirmed), do: "Delivery"
  defp kernel_stage(:reaction_recorded), do: "Feedback"
  defp kernel_stage(:episode_cancelled), do: "Cancellation"
  defp kernel_stage(_kind), do: "Lifecycle"

  # A wait an edit ended is not "what Ryker was waiting for arrived": the
  # edit replaced the question and started the work again (QA re-test,
  # 2026-09-26).
  defp title(:wait_resumed, %Entry{event_kind: :edit}), do: "Picked up again after an edit"
  defp title(kind, _input), do: Words.lifecycle_title(kind)

  defp summary(:wait_resumed, %{"expected_wait" => %{"kind" => "input"}}, %Entry{
         event_kind: :edit
       }) do
    "The message was edited while Ryker waited, so the question it asked was replaced and the work started again from the new wording."
  end

  defp summary(:wait_resumed, _payload, %Entry{event_kind: :edit}) do
    "The message was edited while Ryker waited, so the work started again from the new wording."
  end

  defp summary(kind, payload, _input), do: lifecycle_summary(kind, payload)

  defp lifecycle_summary(:input_admitted, _payload), do: "Message added to this request."

  # A run is handed on when the one that stopped is started again: for a newer
  # message, once the conversation can be reached again, or by a person's retry.
  defp lifecycle_summary(:owner_transferred, %{"required_input_ref" => ref}) when is_binary(ref),
    do: "A newer message arrived, so Ryker stopped the earlier run and started a new one with it."

  defp lifecycle_summary(:owner_transferred, %{
         "transfer_ref" => "transfer:resume-destination:" <> _
       }),
       do: "Ryker could reach the conversation again, so it started a new run to finish the work."

  defp lifecycle_summary(:owner_transferred, %{"transfer_ref" => "transfer:resume-blocked:" <> _}),
       do: "The run had stopped, and a retry started it again as a new run."

  defp lifecycle_summary(:owner_transferred, _payload),
    do: "The run that stopped was started again as a new run."

  defp lifecycle_summary(:input_wait_started, _payload),
    do: "Ryker asked a question and paused until someone answers it."

  defp lifecycle_summary(:event_wait_started, _payload),
    do: "Ryker paused until the event it waits for happens or its deadline passes."

  defp lifecycle_summary(:wait_resumed, _payload),
    do: "What Ryker was waiting for arrived, so the work continues."

  defp lifecycle_summary(:result_accepted, _payload),
    do: "Ryker checked the answer and accepted it."

  defp lifecycle_summary(:delivery_confirmed, _payload), do: "Delivery was confirmed."

  defp lifecycle_summary(:episode_cancelled, _payload),
    do: "This request was stopped and will not continue."

  defp lifecycle_summary(:reaction_recorded, _payload),
    do: "Ryker noted the reaction for its next run."

  defp lifecycle_summary(_kind, _payload), do: "Ryker recorded a change to this request."

  defp kernel_tone(kind) when kind in [:result_accepted, :delivery_confirmed, :wait_resumed],
    do: :good

  defp kernel_tone(:episode_cancelled), do: :warn
  defp kernel_tone(_kind), do: nil

  @doc """
  How evidence was gathered across conversations.

  One piece of work can be reported in several places. An operator reading
  this trace has to see where its evidence actually came from, or an episode
  gathering evidence from three channels looks like one thread.
  """
  def association_steps(%Episode{} = episode) do
    origins = Origins.for_episode(episode.id)
    conversations = origins |> Enum.map(& &1.conversation_ref) |> Enum.uniq()

    gathered_steps(episode, origins, conversations)
  end

  defp gathered_steps(_episode, _origins, conversations) when length(conversations) < 2, do: []

  defp gathered_steps(episode, origins, conversations) do
    [
      step("origins-#{episode.id}", :ready, List.last(origins).occurred_at, %{
        actor: "Ryker",
        stage: "Routing",
        state: "",
        title: "Evidence joined from #{length(conversations)} conversations",
        summary:
          "Membership is per message: progress stays in one home and each message is answered where it was written.",
        details:
          compact_details([
            {"Progress home", episode.destination_conversation_ref},
            {"Contributing conversations", Enum.join(conversations, ", ")},
            {"Messages", length(origins)}
          ])
      })
    ]
  end

  @doc "A link to the source message of the first input that has one, or nil."
  def source_link(episode, events, inputs) do
    events
    |> Enum.find_value(fn event ->
      case event_input(event, inputs) do
        %Entry{} = input -> entry_source_link(episode, input)
        nil -> nil
      end
    end)
  end

  @doc """
  A link to one message where it was sent, for a message that has no request
  of its own: the Slack message in its thread, the Chat, or the GitHub comment.
  """
  @spec message_link(Entry.t()) :: map() | nil
  def message_link(%Entry{} = input), do: entry_source_link(input, input)

  # The destination is where the reply went: the episode's, or the message's
  # own when it started no request.
  defp entry_source_link(
         %{
           destination_conversation_ref: "slack:" <> conversation,
           destination_thread_ref: thread
         },
         %Entry{source_item_ref: message_ref}
       ) do
    with [_workspace, channel] <- String.split(conversation, ":", parts: 2),
         true <- slack_ref?(channel),
         true <- slack_timestamp?(message_ref) do
      stamp = "p" <> String.replace(message_ref, ".", "")
      base = "https://slack.com/archives/#{channel}/#{stamp}"

      href =
        if slack_timestamp?(thread) and thread != message_ref,
          do: base <> "?" <> URI.encode_query(%{"cid" => channel, "thread_ts" => thread}),
          else: base

      %{href: href, label: "Open in Slack", transport: "Slack"}
    else
      _invalid -> nil
    end
  end

  defp entry_source_link(
         %{destination_conversation_ref: "control-plane:lab:" <> conversation_id},
         _input
       ) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, id} ->
        %{
          href: "/conversations/#{id}",
          label: "Open in Chat",
          transport: "Conversation"
        }

      :error ->
        nil
    end
  end

  defp entry_source_link(
         _episode,
         %Entry{
           source_kind: "github",
           source_item_ref: source_item_ref,
           content: %{"payload" => payload}
         }
       )
       when is_map(payload) do
    repository = get_in(payload, ["repository", "full_name"])
    number = get_in(payload, ["issue", "number"]) || get_in(payload, ["pull_request", "number"])
    comment_id = get_in(payload, ["comment", "id"])
    review_id = get_in(payload, ["review", "id"])
    pull? = is_map(get_in(payload, ["issue", "pull_request"]))

    github_source_link(repository, number, comment_id, review_id, source_item_ref, pull?)
  end

  defp entry_source_link(_episode, _input), do: nil

  defp slack_ref?(value), do: is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value)

  defp slack_timestamp?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, value)

  defp github_repository?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:pull_request_review_comment:" <> _item_id,
         _pull?
       ),
       do: github_comment_link(repository, number, comment_id, "pull", "discussion_r")

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:issue_comment:" <> _item_id,
         true
       ),
       do: github_comment_link(repository, number, comment_id, "pull", "issuecomment-")

  defp github_source_link(
         repository,
         number,
         comment_id,
         _review_id,
         "github:issue_comment:" <> _item_id,
         false
       ),
       do: github_comment_link(repository, number, comment_id, "issues", "issuecomment-")

  defp github_source_link(
         repository,
         number,
         _comment_id,
         review_id,
         "github:pull_request_review:" <> _item_id,
         _pull?
       ),
       do: github_review_link(repository, number, review_id)

  defp github_source_link(
         _repository,
         _number,
         _comment_id,
         _review_id,
         _source_item_ref,
         _pull?
       ),
       do: nil

  defp github_comment_link(repository, number, comment_id, path, anchor) do
    if github_repository?(repository) and is_integer(number) and is_integer(comment_id) do
      %{
        href: "https://github.com/#{repository}/#{path}/#{number}##{anchor}#{comment_id}",
        label: "Open in GitHub",
        transport: "GitHub"
      }
    end
  end

  defp github_review_link(repository, number, review_id) do
    if github_repository?(repository) and is_integer(number) and is_integer(review_id) do
      %{
        href: "https://github.com/#{repository}/pull/#{number}#pullrequestreview-#{review_id}",
        label: "Open in GitHub",
        transport: "GitHub"
      }
    end
  end
end
