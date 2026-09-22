defmodule Ryker.ControlPlane.EpisodeTrace.Input do
  @moduledoc """
  "What came in": the kernel's lifecycle events tied back to the inputs that
  caused them, how evidence was gathered across conversations and corrected
  by operators, and the link to the source message.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.Episodes.{AssociationCorrection, Episode, Origins}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  @doc "The episode's admitted inputs, oldest first, bounded."
  @spec rows(Ecto.UUID.t()) :: [Entry.t()]
  def rows(episode_id) do
    Repo.all(
      from(entry in Entry,
        where: entry.episode_id == ^episode_id,
        order_by: [asc: entry.occurred_at, asc: entry.id],
        limit: 200
      )
    )
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
      Repo.one(
        from(entry in Entry,
          where: entry.episode_id == ^episode.id,
          select: min(entry.inserted_at)
        )
      )

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

  @doc "One step per durable kernel event, owned by the input that caused it."
  def kernel_steps(events, inputs) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} ->
      input = event_input(event, inputs)

      step(
        "kernel-#{event.sequence || index}",
        kernel_band(event.kind),
        event.occurred_at,
        %{
          actor: "Episode kernel",
          input_id: input && input.id,
          owner: if(input, do: {:input, input.id}, else: :episode),
          delivery_ref: get_in(event.payload || %{}, ["expected_delivery_ref"]),
          result_ref: get_in(event.payload || %{}, ["result_ref"]),
          # The source card owns input identity, message metadata and retained
          # bodies. Repeating those facts on every durable transition made the
          # timeline look like it contained new evidence when it did not.
          details: [],
          stage: kernel_stage(event.kind),
          state: event.kind,
          summary: kernel_summary(event.kind),
          title: kernel_title(event.kind),
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

  defp kernel_title(kind), do: kind |> human() |> capitalize()

  defp kernel_summary(:input_admitted), do: "Message added to this request."

  defp kernel_summary(:owner_transferred),
    do: "The kernel transferred exclusive responsibility for the next transition."

  defp kernel_summary(:input_wait_started),
    do: "Work parked until a person supplies the requested information."

  defp kernel_summary(:event_wait_started),
    do: "Work parked until an exact event or deadline resumes it."

  defp kernel_summary(:wait_resumed),
    do: "The recorded wait matched and work became eligible again."

  defp kernel_summary(:result_accepted), do: "Ryker accepted the host-validated result."

  defp kernel_summary(:delivery_confirmed),
    do: "Delivery was confirmed."

  defp kernel_summary(:episode_cancelled), do: "The episode reached a durable cancelled state."

  defp kernel_summary(:reaction_recorded),
    do: "Conversation feedback was recorded for the next logical turn."

  defp kernel_summary(_kind), do: "Durable lifecycle transition recorded."

  defp kernel_tone(kind) when kind in [:result_accepted, :delivery_confirmed, :wait_resumed],
    do: :good

  defp kernel_tone(:episode_cancelled), do: :warn
  defp kernel_tone(_kind), do: nil

  @doc """
  How evidence was gathered across conversations and corrected by operators.

  One piece of work can be reported in several places. An operator reading
  this trace has to see where its evidence actually came from, which signals
  are still firing, and every audited change of membership -- otherwise a
  merged episode looks like it simply lost its messages.
  """
  def association_steps(%Episode{} = episode) do
    origins = Origins.for_episode(episode.id)
    conversations = origins |> Enum.map(& &1.conversation_ref) |> Enum.uniq()

    gathered_steps(episode, origins, conversations) ++ correction_steps(episode)
  end

  defp gathered_steps(_episode, _origins, conversations) when length(conversations) < 2, do: []

  defp gathered_steps(episode, origins, conversations) do
    [
      step("origins-#{episode.id}", :ready, List.last(origins).occurred_at, %{
        actor: "Episode kernel",
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

  defp correction_steps(%Episode{} = episode) do
    Repo.all(
      from(correction in AssociationCorrection,
        where:
          correction.source_episode_id == ^episode.id or
            correction.target_episode_id == ^episode.id,
        order_by: [asc: correction.applied_at]
      )
    )
    |> Enum.map(fn correction ->
      step("association-#{correction.id}", :ready, correction.applied_at, %{
        actor: "Operator",
        stage: "Routing",
        state: Atom.to_string(correction.kind),
        title: correction_title(correction, episode),
        summary: correction.reason,
        details:
          compact_details([
            {"Confirmed by", correction.actor_ref, identifier: true},
            {"Confirmation", correction.confirmation_ref, identifier: true},
            {"Messages moved", length(correction.input_refs)}
          ])
      })
    end)
  end

  defp correction_title(%{kind: :merge, source_episode_id: id}, %Episode{id: id}),
    do: "Merged into another episode by an audited correction"

  defp correction_title(%{kind: :merge}, _episode),
    do: "Absorbed another episode by an audited correction"

  defp correction_title(%{kind: :split}, _episode),
    do: "Messages removed from this work by an audited correction"

  defp correction_title(%{kind: :reassign, source_episode_id: id}, %Episode{id: id}),
    do: "Messages moved to another episode by an audited correction"

  defp correction_title(%{kind: :reassign}, _episode),
    do: "Messages moved into this episode by an audited correction"

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

  defp entry_source_link(
         %Episode{
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

      %{href: href, label: "Open source message", transport: "Slack"}
    else
      _invalid -> nil
    end
  end

  defp entry_source_link(
         %Episode{destination_conversation_ref: "control-plane:lab:" <> conversation_id},
         _input
       ) do
    case Ecto.UUID.cast(conversation_id) do
      {:ok, id} ->
        %{
          href: "/conversations/#{id}",
          label: "Open source conversation",
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
        label: "Open source comment",
        transport: "GitHub"
      }
    end
  end

  defp github_review_link(repository, number, review_id) do
    if github_repository?(repository) and is_integer(number) and is_integer(review_id) do
      %{
        href: "https://github.com/#{repository}/pull/#{number}#pullrequestreview-#{review_id}",
        label: "Open source review",
        transport: "GitHub"
      }
    end
  end
end
