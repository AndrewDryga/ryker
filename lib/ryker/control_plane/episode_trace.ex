defmodule Ryker.ControlPlane.EpisodeTrace do
  alias Ryker.ControlPlane.{SlackMarkdown, SlackNames}
  alias Ryker.Slack.ThreadStatusReceipts

  @moduledoc """
  Builds the bounded operator story for one durable episode.

  This projection deliberately presents identities, lifecycle, measurements,
  and host decisions rather than copying raw ingress, prompts, candidates, or
  provider diagnostics into the control plane.
  """

  import Ecto.Query

  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.Card
  alias Ryker.ControlPlane.CurrentInputs
  alias Ryker.ControlPlane.EpisodeCausality
  alias Ryker.ControlPlane.EvidenceLinks
  alias Ryker.ControlPlane.InspectionRedactor
  alias Ryker.ControlPlane.LearningActivity
  alias Ryker.ControlPlane.ProviderMessage
  alias Ryker.ControlPlane.SourceText
  alias Ryker.ControlPlane.WorkRecovery
  alias Ryker.CoopFleet.Event, as: CoopEvent
  alias Ryker.CoopFleet.Placement
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes.{AssociationCorrection, CorrelationClaims, Episode, Event, Origins}
  alias Ryker.Ingress.Inbox

  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.InputMembership
  alias Ryker.Operator.EpisodeReview
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.IncidentRoom
  alias Ryker.State.{Behaviors, CaseRecord, LearningRun, Record, Schedule}

  alias Ryker.Work.{Activity, ActivityEvent, ActivityPaths, Session, Turn}

  @chapters [
    {:input, "What came in", "The input, continuation, or trigger that opened this work."},
    {:ready, "Getting ready", "How Ryker routed, scoped, and prepared the work."},
    {:routing, "Routing", "The routing model's briefing, activity, and decision."},
    {:work, "The work", "What ran, what it recorded, and whether the provider stayed active."},
    {:answer, "The answer", "Candidate validation, the accepted result, and any refusal."},
    {:outcome, "What came of it", "Delivery, durable side effects, waits, and follow-up work."},
    {:learning, "Learning",
     "Background learning from these messages. It runs on its own and sends no reply."},
    {:maintenance, "Maintenance",
     "What happened to the temporary session and workspace afterwards."}
  ]

  @spec project(Episode.t(), [Event.t()], [Record.t()], keyword()) :: map()
  def project(episode, events, records, options \\ [])

  def project(%Episode{} = episode, events, records, options)
      when is_list(events) and is_list(records) do
    input_rows = input_rows(episode.id)
    inputs = inputs_by_ref(input_rows)
    sessions = sessions(episode.id)
    turns = turns(episode.id)
    disclosed = Keyword.get(options, :disclosed) || MapSet.new()

    activity_page =
      Activity.page_for_episode(episode.id, Keyword.get(options, :activity_pages, 1))

    causality =
      EpisodeCausality.index(input_rows, turns, activity_page.events,
        input_refs: input_refs(events, inputs)
      )

    activity =
      activity_page.events
      |> activity_steps(causality, disclosed)
      |> EvidenceLinks.attach(activity_page.events, turns, records)

    current_turn = List.last(turns)
    stopped = stopped(episode, current_turn)
    # Only collapse an entirely unstarted task, never earlier work in a resumed episode.
    startup =
      if current_blocked_turn?(episode, current_turn) and length(turns) == 1 and
           WorkRecovery.not_started?(current_turn) and
           Enum.all?(sessions, &is_nil(&1.coop_session_id)),
         do: task_start(episode, current_turn)

    totals = totals(episode.id, events, records, sessions, turns)
    review = review_state(episode)
    received_at = first_received_at(episode)
    platform_actions = platform_actions(episode.id)
    publications = publications(episode.id)
    source = source_link(episode, events, inputs)

    steps =
      []
      |> Kernel.++(kernel_steps(events, inputs))
      |> Kernel.++(association_steps(episode))
      |> Kernel.++(preparation_steps(input_rows))
      |> Kernel.++(setup_steps(sessions, turns))
      |> Kernel.++(turn_steps(turns, sessions))
      |> Kernel.++(activity)
      |> Kernel.++(slack_status_steps(episode.id))
      |> Kernel.++(record_steps(records))
      |> Kernel.++(coop_steps(sessions))
      |> Kernel.++(platform_action_steps(platform_actions))
      |> Kernel.++(incident_steps(episode.id))
      |> Kernel.++(publication_steps(publications))
      |> Kernel.++(schedule_steps(episode.id))
      |> Kernel.++(learning_steps(input_rows))
      |> Kernel.++(maintenance_steps(sessions))
      |> chronological()

    %{
      activity:
        activity_page
        |> Map.drop([:events])
        |> Map.put(
          :more,
          next_activity_page(activity_page, Keyword.get(options, :activity_pages, 1))
        ),
      actions: operator_actions(episode, current_turn, review),
      case_file: case_file(episode.id, turns, sessions, disclosed),
      startup: startup,
      causality: causality,
      chapters: chapters(steps, received_at, causality),
      follow_through: follow_through(platform_actions, publications, source),
      history: history(totals, activity_page),
      metrics: metrics(episode, received_at, activity_page, totals, steps),
      next_action: next_action(episode, current_turn),
      received_at: received_at,
      review: review,
      source: source,
      stats: stats(steps, activity_page, totals),
      steps: steps,
      stopped: stopped
    }
  end

  # Only offer another page when one exists and the bound has not been reached.
  defp next_activity_page(%{truncated: true}, pages) when pages < 10, do: pages + 1
  defp next_activity_page(_page, _pages), do: nil

  # One piece of work can be reported in several places. An operator reading
  # this trace has to see where its evidence actually came from, which signals
  # are still firing, and every audited change of membership -- otherwise a
  # merged episode looks like it simply lost its messages.
  defp association_steps(%Episode{} = episode) do
    origins = Origins.for_episode(episode.id)
    conversations = origins |> Enum.map(& &1.conversation_ref) |> Enum.uniq()

    gathered_steps(episode, origins, conversations) ++ correction_steps(episode)
  end

  defp gathered_steps(_episode, _origins, conversations) when length(conversations) < 2, do: []

  defp gathered_steps(episode, origins, conversations) do
    claims = CorrelationClaims.for_episode(episode.id)
    firing = Enum.count(claims, &(&1.status == :active and &1.lifecycle_state == :active))

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
            {"Messages", length(origins)},
            {"Signals still firing", if(claims != [], do: "#{firing} of #{length(claims)}")},
            {"Retained case", retained_case_ref(episode.id)}
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
            {"Confirmed by", correction.actor_ref},
            {"Confirmation", correction.confirmation_ref},
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

  defp retained_case_ref(episode_id) do
    Repo.one(
      from(record in CaseRecord,
        where: record.episode_id == ^episode_id and record.status == :active,
        select: record.case_ref
      )
    )
  end

  defp slack_status_steps(episode_id) do
    Enum.map(ThreadStatusReceipts.for_episode(episode_id), fn receipt ->
      clear = receipt.text == ""

      band = status_band(receipt)

      step("slack-status-#{receipt.id}", band, receipt.acknowledged_at || receipt.inserted_at, %{
        actor: "Slack",
        stage: "Status",
        state: if(receipt.error, do: "failed", else: ""),
        title: status_title(receipt),
        summary: receipt.error || if(clear, do: nil, else: receipt.text),
        details:
          compact_details([
            {"Confirmation",
             if(receipt.acknowledged_at, do: "Slack acknowledged this status update.")},
            {"Status generation", receipt.generation}
          ]),
        tone: if(receipt.error, do: :warn)
      })
    end)
  end

  defp status_band(%{text: ""}), do: :outcome

  defp status_band(%{phase: phase}) when phase in ~w(queued admitting admission_retry),
    do: :routing

  defp status_band(_), do: :work
  defp status_title(%{error: error}) when is_binary(error), do: "Slack status update failed"
  defp status_title(%{text: ""}), do: "Slack working status cleared"
  defp status_title(_), do: "Slack working status set"

  defp case_file(episode_id, turns, sessions, disclosed) do
    options = [
      secrets: InspectionRedactor.configured_secrets(),
      max_bytes: 12_000,
      disclosed: disclosed
    ]

    base = from(entry in subquery(CurrentInputs.for_episode(episode_id)))

    first =
      Repo.one(from(entry in base, order_by: [asc: entry.occurred_at, asc: entry.id], limit: 1))

    first = if first, do: case_message(first, options)

    messages =
      Repo.all(
        from(entry in base, order_by: [desc: entry.occurred_at, desc: entry.id], limit: 20)
      )
      |> Enum.reverse()
      |> Enum.map(&case_message(&1, options))

    replies = turns |> Enum.flat_map(&case_reply(&1, options)) |> Enum.take(-20)
    latest_reply = List.last(replies)
    current_turn = List.last(turns)

    task_session = task_session(current_turn, sessions)

    %{
      title: task_title(task_session) || input_title(first),
      expired_at: Enum.find_value(messages, & &1.expired_at),
      messages: messages,
      repository: case_repository(task_session, first),
      reply: latest_reply && latest_reply.text,
      reply_status: latest_reply && latest_reply.status,
      reply_request_id: latest_reply && latest_reply.id,
      awaiting_reply: is_nil(current_turn) or is_nil(current_turn.delivery_document),
      conversation:
        Enum.sort_by(messages ++ Enum.filter(replies, & &1.delivered), & &1.at, DateTime)
    }
  end

  defp task_session(%Turn{operational_pruned_at: nil, session_id: id}, sessions),
    do: Enum.find(sessions, &(&1.id == id and is_map(&1.workspace_task)))

  defp task_session(_, _), do: nil

  defp task_title(%Session{workspace_task: %{"title" => title}}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 240).text

  defp task_title(_), do: nil

  defp input_title(%{available: true, text: text} = first) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> SlackMarkdown.plain(first[:workspace])
    |> bounded(120)
  end

  defp input_title(_), do: "Episode case file"

  defp case_repository(%Session{repository_ref: ref}, _) when is_binary(ref), do: ref
  defp case_repository(_, first), do: first && first.repository

  defp task_start(episode, turn) do
    offer =
      Repo.one(
        from(record in Record,
          join: source in Episode,
          on: source.id == record.episode_id,
          where: record.kind == "task_offer" and record.status == :confirmed,
          where: record.confirmed_episode_id == ^episode.id,
          where: record.episode_id == ^(episode.linked_episode_id || episode.id),
          select: %{
            inserted_at: record.inserted_at,
            confirmed_at: record.confirmed_at,
            episode_key: source.key
          },
          order_by: [desc: record.confirmed_at, desc: record.id],
          limit: 1
        )
      )

    %{
      confirmed: not is_nil(offer) and not is_nil(offer.confirmed_at),
      events:
        Enum.reject(
          [
            offer &&
              %{
                label: "Task proposed",
                at: offer.inserted_at,
                href: "/timeline/" <> segment(offer.episode_key)
              },
            offer && offer.confirmed_at &&
              %{label: "Task approved", at: offer.confirmed_at, href: nil},
            %{
              label: "Couldn’t start — code-editing setup needs attention",
              at: turn.cancelled_at || turn.updated_at,
              href: nil
            }
          ],
          &is_nil/1
        )
    }
  end

  defp case_reply(
         %{operational_pruned_at: nil, delivery_document: %{"message" => text}} = turn,
         options
       )
       when is_binary(text) do
    artifact = InspectionRedactor.artifact(text, options)

    [
      %{
        id: turn.id,
        owner: {:turn, turn.id},
        at: turn.delivered_at || turn.accepted_at || turn.inserted_at,
        actor: "Ryker",
        delivery_ref: turn.delivery_ref,
        delivered: not is_nil(turn.delivered_at),
        status: case_reply_status(turn),
        text: artifact.text,
        available: artifact.state == :retained,
        href: "model-calls?attempt=#{turn.id}&section=delivery"
      }
    ]
  end

  defp case_reply(_, _), do: []

  defp case_message(input, options) do
    artifact =
      InspectionRedactor.artifact(
        if(is_nil(input.operational_pruned_at),
          do:
            if(input.event_kind == :delete,
              do: "Message deleted",
              else: SourceText.from_content(input.content)
            )
        ),
        Keyword.put(options, :expired, not is_nil(input.operational_pruned_at))
      )

    %{
      id: input.id,
      owner: {:input, input.id},
      at: input.occurred_at,
      transport: input.destination_transport,
      # "User" told a reader nothing they could act on. Slack writes a person as
      # @name, so the page does too, and says which workspace they are from.
      actor: actor_label(input),
      display_actor:
        if(input.source_kind == "slack",
          do: SlackNames.name(input.source_ref, input.actor_ref)
        ),
      actor_ref: input.actor_ref,
      workspace: if(input.source_kind == "slack", do: input.source_ref),
      text: artifact.text,
      available: artifact.state == :retained,
      repository: input.repository_ref,
      expired_at: input.operational_pruned_at,
      href: "/timeline/ingress-input%3A#{input.id}",
      event_kind: input.event_kind,
      provider:
        if(is_nil(input.operational_pruned_at),
          do: ProviderMessage.recognize(input.source_kind, input.content)
        ),
      details: input_details(input, options)
    }
  end

  defp actor_label(%{actor_kind: :user, source_kind: "slack"}), do: "Slack user"
  defp actor_label(%{actor_kind: :user}), do: "User"
  defp actor_label(_input), do: "Source event"

  # Input details, in the approved order: readable extracted metadata first,
  # then the raw source envelope, the normalized input and the original message
  # as independently collapsed bodies. Raw is the adapter's payload; normalized
  # is what Ryker made of it; neither is ever shown under the other's name.
  defp input_details(input, options) do
    expired = not is_nil(input.operational_pruned_at)
    disclosed = Keyword.get(options, :disclosed, MapSet.new())
    raw_id = "input-#{input.id}-raw"
    normalized_id = "input-#{input.id}-normalized"

    %{
      metadata: input_metadata(input),
      raw: %{
        absent: raw_absent(input),
        artifact_id: raw_id,
        artifact: raw_envelope(input, expired, MapSet.member?(disclosed, raw_id), options)
      },
      normalized: %{
        artifact_id: normalized_id,
        artifact:
          InspectionRedactor.artifact(
            unless(expired, do: input.content),
            Keyword.merge(options,
              expired: expired,
              max_bytes: 64 * 1_024,
              disclosed: MapSet.member?(disclosed, normalized_id)
            )
          )
      }
    }
  end

  defp input_metadata(input) do
    compact_details([
      {"Source", source_label(input.source_kind)},
      {"Event", input_event_label(input.event_kind)},
      {"Event ID", input.event_ref},
      {"Message ID", input.source_item_ref},
      {"Sender ID", join_ref(input.actor_kind, input.actor_ref)},
      {"Conversation", input.destination_conversation_ref},
      {"Thread", input.destination_thread_ref},
      {"Source revision", input.revision},
      {"Source event time",
       "#{timestamp_precise(input.occurred_at)} · #{provenance_label(input.occurred_at_source)}"},
      {"Recorded by Ryker", timestamp_precise(input.inserted_at)},
      {"Execution mode", input.execution_mode}
    ])
  end

  # A control-plane input is typed into Ryker itself, so no adapter stands
  # between the person and the record. Reporting that one failed to hand over a
  # payload blamed a hand-over that never happens for this source.
  defp raw_absent(%{source_kind: "control_plane"}),
    do: "This input was submitted directly in the control plane, so no adapter payload exists."

  defp raw_absent(_input),
    do:
      "The adapter did not hand over its source payload for this input, so there is no raw " <>
        "record; the normalized input below is not a substitute."

  defp raw_envelope(_input, true, _disclosed?, _options),
    do: %{state: :expired, text: nil, sha256: nil, bytes: nil, redacted: false, truncated: false}

  defp raw_envelope(%{source_envelope: nil}, _expired, _disclosed?, _options),
    do: %{
      state: :not_recorded,
      text: nil,
      sha256: nil,
      bytes: nil,
      redacted: false,
      truncated: false
    }

  defp raw_envelope(%{source_envelope: %{"omitted" => reason} = marker}, _expired, _d, _options)
       when map_size(marker) <= 3 do
    %{
      state: :omitted,
      reason: reason,
      omitted_bytes: marker["bytes"],
      text: nil,
      sha256: nil,
      bytes: nil,
      redacted: false,
      truncated: false
    }
  end

  defp raw_envelope(%{source_envelope: envelope}, _expired, disclosed?, options) do
    InspectionRedactor.artifact(
      envelope,
      Keyword.merge(options, max_bytes: 64 * 1_024, disclosed: disclosed?)
    )
  end

  defp source_label("slack"), do: "Slack"
  defp source_label("github"), do: "GitHub"
  defp source_label("control_plane"), do: "Direct conversation"
  defp source_label("webhook"), do: "Webhook"
  defp source_label(other), do: to_string(other)

  defp input_event_label(:message), do: "New message"
  defp input_event_label(:edit), do: "Message edited"
  defp input_event_label(:delete), do: "Message deleted"
  defp input_event_label(:event), do: "Source event"
  defp input_event_label(other), do: to_string(other)

  defp provenance_label(:source), do: "time reported by the source"
  defp provenance_label(:ingress), do: "time assigned at ingress; the source gave none"
  defp provenance_label(other), do: to_string(other)

  defp timestamp_precise(%DateTime{} = value),
    do: Calendar.strftime(value, "%d %b %Y %H:%M:%S.%f UTC")

  defp timestamp_precise(_value), do: "Not recorded"

  defp case_reply_status(%{
         delivered_at: %DateTime{},
         external_receipt: %{"message_ref" => "eval-message:" <> _}
       }),
       do: "Response captured in private replay"

  defp case_reply_status(%{delivered_at: %DateTime{}}), do: "Response sent"
  defp case_reply_status(%{accepted_at: %DateTime{}}), do: "Accepted · delivery not confirmed"
  defp case_reply_status(_turn), do: nil

  defp input_rows(episode_id) do
    Repo.all(
      from(entry in Entry,
        where: entry.episode_id == ^episode_id,
        order_by: [asc: entry.occurred_at, asc: entry.id],
        limit: 200
      )
    )
  end

  # A turn records its selection with the kernel's own input references, so the
  # projection needs the kernel's mapping from those references back to inputs.
  # Nothing else can resolve them: matching on the closest recorded time is the
  # guess this whole grouping exists to stop making.
  defp input_refs(events, inputs) do
    for event <- events,
        input = event_input(event, inputs),
        into: %{},
        do: {event.dedupe_key, input.id}
  end

  defp inputs_by_ref(rows) do
    rows
    |> Enum.flat_map(&[{&1.dedupe_key, &1}, {"ingress-turn:#{&1.id}", &1}])
    |> Map.new()
  end

  defp first_received_at(episode) do
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

  defp sessions(episode_id) do
    Repo.all(
      from(session in Session,
        where: session.episode_id == ^episode_id,
        order_by: [desc: session.inserted_at, desc: session.id],
        limit: 50
      )
    )
    |> Enum.reverse()
  end

  defp turns(episode_id) do
    Repo.all(
      from(turn in Turn,
        where: turn.episode_id == ^episode_id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 200
      )
    )
    |> Enum.reverse()
  end

  defp kernel_steps(events, inputs) do
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
          details: kernel_details(event, input),
          stage: kernel_stage(event.kind),
          state: event.kind,
          summary: kernel_summary(event.kind),
          title: kernel_title(event.kind),
          tone: kernel_tone(event.kind)
        }
      )
    end)
  end

  defp kernel_details(event, nil) do
    compact_details([
      {"Sequence", event.sequence},
      {"Identity", event.dedupe_key},
      {"Fingerprint", short_digest(event.fingerprint)}
    ])
  end

  defp kernel_details(event, input) do
    compact_details([
      {"Sequence", event.sequence},
      {"Source", join_ref(input.source_kind, input.source_ref)},
      {"Actor", join_ref(input.actor_kind, input.actor_ref)},
      {"Event", input.event_kind},
      {"Revision", input.revision},
      {"Message", source_text(input)},
      {"Attachments", source_attachments(input)},
      {"Fingerprint", short_digest(event.fingerprint)}
    ])
  end

  @doc """
  The Getting ready cards for one input that may have no episode yet.

  The standalone input view shows the same four cards the Timeline shows, read
  from the same rows, so an input that was never picked up explains itself the
  same way as one that was.
  """
  @spec input_preparation(Entry.t()) :: [map()]
  def input_preparation(%Entry{} = input), do: preparation_steps([input])

  @doc """
  The heading a message carries before it becomes an episode.

  The same sentence the episode page shows for a case file: the request itself,
  shortened, and redacted the way every other retained text is.
  """
  @spec unrouted_title(Entry.t()) :: String.t()
  def unrouted_title(%Entry{operational_pruned_at: nil, content: content}) do
    case SourceText.from_content(content) do
      text when is_binary(text) and text != "" ->
        InspectionRedactor.artifact(text, max_bytes: 160).text

      _absent ->
        "Message waiting on routing"
    end
  end

  def unrouted_title(%Entry{}), do: "Message waiting on routing"

  # One Standing rules card per input, always present. The card carries the
  # complete inventory recorded when that input processed, or says plainly
  # that none was recorded. It never reads today's rules: a rule edited since
  # would quietly rewrite the old explanation.
  # Getting ready, per input and in the approved order: Participation settings,
  # then the complete Standing rules inventory, then the Engagement decision,
  # then the Input queue. All four sit at the moment the input was accepted;
  # the list order is the tie-break, so the sequence survives identical
  # timestamps.
  defp preparation_steps(input_rows) do
    inventories = Behaviors.rule_inventories(Enum.map(input_rows, &"ingress-input:#{&1.id}"))
    attempts = first_attempts(input_rows)
    now = DateTime.utc_now()

    Enum.flat_map(input_rows, fn input ->
      receipt = input.engagement_receipt
      inventory = Map.get(inventories, "ingress-input:#{input.id}")
      rules = rule_inventory(inventory)
      participation = participation(receipt)
      engagement = engagement(receipt)
      queue = queue(input, Map.get(attempts, input.id), now)

      [
        step("participation-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          participation: participation,
          details: [],
          stage: "Participation settings",
          state: "",
          summary: participation.summary,
          title: "Participation settings",
          tone: nil
        }),
        step("rules-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          rules: rules,
          details: [],
          stage: "Standing rules",
          state: "",
          summary: rule_summary(rules),
          title: "Standing rules",
          tone: nil
        }),
        step("engagement-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          engagement: engagement,
          details: [],
          stage: "Engagement",
          state: engagement.result,
          summary: engagement.reason,
          title: "Engagement",
          tone: engagement.tone
        }),
        step("queue-#{input.id}", :ready, input.inserted_at, %{
          actor: "Ryker",
          owner: {:input, input.id},
          input_id: input.id,
          queue: queue,
          details: [],
          stage: "Input queue",
          state: queue.label,
          summary: queue.summary,
          title: "Input queue",
          tone: queue.tone
        })
      ]
    end)
  end

  # The earliest admission attempt is the routing claim that first prepared
  # context for the input. Nothing else retains a claim time: claiming clears
  # the retry fields and updated_at moves on every other write.
  defp first_attempts(input_rows) do
    ids = Enum.map(input_rows, & &1.id)

    Repo.all(
      from(attempt in Attempt,
        where: attempt.input_id in ^ids,
        order_by: [asc: attempt.inserted_at, asc: attempt.id]
      )
    )
    |> Enum.group_by(& &1.input_id)
    |> Map.new(fn {input_id, [first | _rest]} -> {input_id, first} end)
  end

  # Saved or not, waiting for what, handed to routing or not. Terminal rows
  # read their durable status; a pending row reads the live queue, and
  # everything derived from the live queue is labelled current because it will
  # not be true for long.
  defp queue(input, first_attempt, now) do
    claimed_at = first_attempt && first_attempt.inserted_at
    wait_ms = if claimed_at, do: nonnegative_diff(claimed_at, input.inserted_at)
    state = queue_state(input, now)

    Map.merge(state, %{
      saved_at: input.inserted_at,
      claimed_at: claimed_at,
      wait_ms: wait_ms,
      claims: input.attempt_count,
      facts: queue_facts(input, state, claimed_at, wait_ms),
      technical: queue_technical(input, state)
    })
  end

  # What happened to this input while it waited: when it arrived, who claimed
  # it, how long that took, and whether it is coming back. The lease belongs
  # here too — it is the claim, not an identifier.
  defp queue_facts(input, state, claimed_at, wait_ms) do
    held? = state.kind == :handed and state.current

    compact_details([
      {"Arrived", timestamp_precise(input.inserted_at)},
      {"Source occurrence", queue_occurrence(input)},
      {"Routing claim", if(claimed_at, do: timestamp_precise(claimed_at), else: "Not recorded")},
      {"Queue wait", format_ms(wait_ms) || "Not recorded"},
      {"Queue claims", input.attempt_count},
      {"Held by", if(held?, do: input.lease_owner)},
      {"Hold expires", if(held?, do: timestamp_precise(input.lease_expires_at))},
      {"Eligible for retry after",
       if(state.kind == :retry, do: timestamp_precise(input.next_attempt_at))},
      {"Last routing error", if(input.status != :decided, do: error_label(input.last_error_code))}
    ])
  end

  # The identifiers somebody debugging this input needs to find it elsewhere.
  # "Source acknowledgement" is gone: no adapter records one, so the row was
  # always "Not recorded".
  defp queue_technical(input, _state) do
    compact_details([
      {"Input / revision", "ingress-input:#{input.id} · revision #{input.revision}"},
      {"Identity", input.dedupe_key},
      {"Event fingerprint", short_digest(input.event_fingerprint)},
      {"Execution mode", capitalize(human(input.execution_mode))},
      {"Execution generation", input.execution_generation},
      {"Validation generation", input.validation_generation}
    ])
  end

  defp queue_state(%Entry{status: :decided}, _now) do
    %{
      kind: :handed,
      label: "Handed to routing",
      summary: "A routing worker picked up this input.",
      current: false,
      tone: :good,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_state(%Entry{status: :superseded}, _now) do
    %{
      kind: :superseded,
      label: "Superseded",
      summary:
        "Input remains saved. A newer revision of this message was already accepted, so this revision's routing choice was not applied.",
      current: false,
      tone: nil,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_state(%Entry{status: :blocked} = input, _now) do
    %{
      kind: :needs_attention,
      label: "Needs attention",
      summary:
        "Input remains saved. Automatic retries have stopped." <>
          queue_error_sentence(input.last_error_code),
      current: false,
      tone: :bad,
      blocker: nil,
      recovery_href: "/failures/admission/#{segment(Inbox.ref(input))}"
    }
  end

  defp queue_state(%Entry{status: :pending} = input, now) do
    cond do
      is_binary(input.lease_ref) and live_after?(input.lease_expires_at, now) ->
        %{
          kind: :handed,
          label: "Handed to routing",
          summary: "A routing worker holds this input.",
          current: true,
          tone: nil,
          blocker: nil,
          recovery_href: nil
        }

      live_after?(input.next_attempt_at, now) ->
        %{
          kind: :retry,
          label: "Waiting to retry",
          summary:
            "Input remains saved." <>
              queue_error_sentence(input.last_error_code) <>
              " Eligible for retry after #{timestamp_precise(input.next_attempt_at)}; a predecessor or an unavailable worker can still delay it.",
          current: true,
          tone: :warn,
          blocker: nil,
          recovery_href: nil
        }

      true ->
        queue_waiting(input, Inbox.queue_predecessor(input, now))
    end
  end

  defp queue_waiting(_input, nil) do
    %{
      kind: :waiting,
      label: "Waiting",
      summary: "Saved; waiting for routing pickup.",
      current: true,
      tone: nil,
      blocker: nil,
      recovery_href: nil
    }
  end

  defp queue_waiting(_input, %Entry{} = predecessor) do
    %{
      kind: :waiting,
      label: "Waiting",
      summary: "Waiting for an earlier input in this conversation.",
      current: true,
      tone: nil,
      blocker: %{
        text: queue_blocker_text(predecessor),
        href: "/timeline/ingress-input%3A#{predecessor.id}"
      },
      recovery_href: nil
    }
  end

  defp queue_blocker_text(%Entry{operational_pruned_at: nil, content: content}) do
    case SourceText.from_content(content) do
      text when is_binary(text) and text != "" ->
        InspectionRedactor.artifact(text, max_bytes: 120).text

      _absent ->
        "Earlier input"
    end
  end

  defp queue_blocker_text(_predecessor), do: "Earlier input"

  defp queue_error_sentence(nil), do: ""
  defp queue_error_sentence(code), do: " " <> error_label(code) <> "."

  defp error_label(nil), do: nil
  defp error_label(code), do: code |> human() |> capitalize() |> bounded(200)

  defp queue_occurrence(%Entry{event_kind: :message}), do: "New input"
  defp queue_occurrence(%Entry{event_kind: :edit}), do: "Edited message · new revision"
  defp queue_occurrence(%Entry{event_kind: :delete}), do: "Deleted message · new revision"
  defp queue_occurrence(%Entry{event_kind: kind}), do: capitalize(human(kind))

  defp live_after?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :gt
  defp live_after?(_at, _now), do: false

  # Effective proactive/shadow values with the source each one won from. An
  # explicit submission never consulted channel settings, and history without
  # a receipt says "not recorded" rather than reading today's configuration.
  defp participation(nil),
    do: %{
      state: :not_recorded,
      settings: [],
      summary: "Effective participation settings were not recorded for this input."
    }

  defp participation(%{"settings" => %{} = settings}) do
    rows =
      for key <- ["proactive", "shadow"], %{} = setting <- [settings[key]] do
        %{
          label: participation_label(key),
          value: if(setting["value"] == true, do: "On", else: "Off"),
          source: setting_source_label(setting["source"])
        }
      end

    %{
      state: :recorded,
      settings: rows,
      summary: Enum.map_join(rows, " · ", &"#{&1.label} #{&1.value}")
    }
  end

  defp participation(%{"path" => path}) do
    %{
      state: :not_applicable,
      settings: [],
      summary: "Not applicable: #{path_label(path)} bypasses channel participation settings."
    }
  end

  defp participation(_receipt), do: participation(nil)

  defp participation_label("proactive"), do: "Proactive"
  defp participation_label("shadow"), do: "Shadow"
  defp participation_label(other), do: to_string(other)

  defp setting_source_label("channel"), do: "Saved channel setup"
  defp setting_source_label("configuration"), do: "Channel configuration"
  defp setting_source_label("workspace"), do: "Workspace setting"
  defp setting_source_label("deployment"), do: "Deployment default"
  defp setting_source_label("incident_room"), do: "Incident room policy"
  defp setting_source_label("watch_channels"), do: "Watched channel list"
  defp setting_source_label(nil), do: "Source not recorded"
  defp setting_source_label(other), do: human(to_string(other))

  defp path_label("conversation_lab"), do: "an explicit direct-conversation submission"
  defp path_label("slack_shortcut"), do: "an explicit Slack shortcut"
  defp path_label("slack_event"), do: "a Slack event"
  defp path_label(other), do: human(to_string(other))

  # The decision as it was made: result, plain reason, and every predicate the
  # gate reached. A predicate it never reached is "not checked" -- the receipt
  # does not know its answer and neither does anyone else.
  @engagement_checks [
    {"direct_or_mention", "Direct message / mention"},
    {"existing_episode_thread", "Existing episode thread"},
    {"standing_rule", "Standing rule"},
    {"proactive_participation", "Proactive participation"},
    {"shadow_evaluation", "Shadow evaluation"}
  ]

  defp engagement(nil),
    do: %{
      state: :not_recorded,
      result: "",
      tone: nil,
      reason: "The engagement decision was not recorded for this input.",
      path: nil,
      checks: []
    }

  defp engagement(%{"result" => result} = receipt) do
    # A receipt is retained JSON written by an older version of the gate. One
    # whose shape no longer parses is one card's absence; crashing here would
    # take the whole page with it.
    recorded =
      receipt["checks"]
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Map.new(&{&1["check"], &1["outcome"]})

    checks =
      if recorded == %{} do
        []
      else
        Enum.map(@engagement_checks, fn {key, label} ->
          %{label: label, outcome: check_outcome(Map.get(recorded, key))}
        end)
      end

    %{
      state: :recorded,
      result: engagement_result(result),
      tone: if(result == "process", do: :good),
      reason: bounded(to_string(receipt["reason"] || ""), 400),
      path: path_label(receipt["path"]),
      execution_mode: receipt["execution_mode"],
      checks: checks
    }
  end

  defp engagement(_receipt), do: engagement(nil)

  defp engagement_result(result) when is_map(result) or is_list(result), do: "Not recorded"
  defp engagement_result("process"), do: "Process"
  defp engagement_result("evaluate_only"), do: "Evaluate only"
  defp engagement_result("not_engaged"), do: "Not picked up"
  defp engagement_result(other), do: human(to_string(other))

  defp check_outcome(nil), do: "Not checked"
  defp check_outcome("yes"), do: "Yes"
  defp check_outcome("no"), do: "No"
  defp check_outcome("matched"), do: "Matched"
  defp check_outcome("not_matched"), do: "Not matched"
  defp check_outcome("on"), do: "On"
  defp check_outcome("off"), do: "Off"
  defp check_outcome(other), do: human(to_string(other))

  defp rule_inventory(nil), do: %{state: :not_recorded, entries: [], truncated: false}

  defp rule_inventory(inventory) do
    entries =
      inventory.entries
      |> Enum.map(fn entry ->
        %{
          ref: entry["ref"],
          title: entry["title"] || entry["ref"],
          status: entry["status"],
          revision: entry["revision"],
          scope_ref: entry["scope_ref"],
          verdict: entry["verdict"],
          reason: InspectionRedactor.artifact(entry["reason"] || "", max_bytes: 400).text
        }
      end)
      |> Enum.sort_by(&{&1.verdict != "matched", &1.title})

    %{
      state: :recorded,
      recorded_at: inventory.recorded_at,
      rule_count: inventory.rule_count,
      matched_count: inventory.matched_count,
      truncated: inventory.truncated,
      entries: entries
    }
  end

  defp rule_summary(%{state: :not_recorded}),
    do: "Standing-rule evaluation was not recorded for this input."

  defp rule_summary(%{rule_count: 0}),
    do: "No standing rules existed when this input was processed."

  defp rule_summary(%{rule_count: total, matched_count: matched}),
    do:
      "#{matched} matched · #{total - matched} other · rules as they existed when this input was processed."

  # One Work setup card per Work turn, before its briefing: the pinned setup
  # versus the actual session, worker and workspace it ran on. A pinned
  # episode that no turn has claimed yet gets one card on its session row,
  # which proves configuration was selected and nothing more.
  defp setup_steps(sessions, turns) do
    work_sessions = Enum.filter(sessions, &(&1.execution_kind == :work))
    sessions_by_id = Map.new(work_sessions, &{&1.id, &1})
    placements = placements(work_sessions)
    now = DateTime.utc_now()

    turn_cards =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {turn, ordinal} ->
        session = Map.get(sessions_by_id, turn.session_id)

        earlier =
          Enum.filter(turns, fn other ->
            other.session_id == turn.session_id and other.id != turn.id and
              DateTime.compare(other.inserted_at, turn.inserted_at) == :lt
          end)

        setup =
          work_setup(turn, ordinal, session, earlier, Map.get(placements, turn.session_id), now)

        step("setup-#{turn.id}", :ready, turn.inserted_at, %{
          actor: "Ryker",
          owner: {:turn, turn.id},
          setup: setup,
          details: [],
          stage: "Work setup",
          state: setup.label,
          summary: setup.summary,
          title: "Work setup",
          tone: setup.tone
        })
      end)

    session_cards =
      if turns == [] do
        Enum.map(work_sessions, fn session ->
          setup = selected_setup(session, Map.get(placements, session.id))

          step("setup-#{session.id}", :ready, session.inserted_at, %{
            actor: "Ryker",
            setup: setup,
            details: [],
            stage: "Work setup",
            state: setup.label,
            summary: setup.summary,
            title: "Work setup",
            tone: nil
          })
        end)
      else
        []
      end

    turn_cards ++ session_cards
  end

  defp placements([]), do: %{}

  defp placements(sessions) do
    ids = Enum.map(sessions, & &1.id)

    Repo.all(
      from(placement in Placement,
        where: placement.session_id in ^ids,
        order_by: [asc: placement.session_id, desc: placement.generation, desc: placement.id]
      )
    )
    |> Enum.uniq_by(& &1.session_id)
    |> Map.new(&{&1.session_id, &1})
  end

  # Ready needs evidence that preparation completed: a bound remote turn is
  # that evidence, because Coop accepts a turn only into a prepared session. A
  # live lease without a bound session is preparation in progress at the one
  # step the rows record. Anything else is "selected", with its outcome
  # unrecorded rather than guessed from today's worker health.
  defp work_setup(turn, ordinal, session, earlier_turns, placement, now) do
    session_state = session_state(session, earlier_turns)
    workspace = setup_workspace(turn)
    worker = setup_worker(session, placement)
    outcome = setup_outcome(turn, session, now)

    Map.merge(outcome, %{
      ordinal: ordinal,
      rows:
        compact_details([
          {"Session", session_state.face},
          {"Worker", worker},
          {"Profile", session && session.policy},
          {"Workspace", workspace.face},
          {"Current step", outcome.current_step}
        ]),
      details: setup_details(turn, session, session_state, worker, workspace),
      technical: setup_technical(turn, session, placement)
    })
  end

  # Ready needs evidence that preparation completed, which is a bound remote
  # turn: Coop accepts a turn only into a prepared session. A live lease with
  # no bound session is preparation in progress at the one step the rows
  # record. Anything else is "selected", with its outcome unrecorded rather
  # than guessed from today's worker health.
  defp setup_outcome(turn, session, now) do
    {kind, label, summary, tone, current_step} =
      cond do
        turn.status == :blocked and is_nil(turn.coop_turn_id) ->
          {:blocked, "Blocked", setup_failure(turn.last_error_code), :bad, nil}

        is_binary(turn.coop_turn_id) or not is_nil(turn.remote_queued_at) ->
          {:ready, "Ready", nil, :good, nil}

        turn.status == :pending and is_binary(turn.lease_ref) and
            live_after?(turn.lease_expires_at, now) ->
          {:preparing, "Preparing", nil, nil, preparing_step(session, turn)}

        true ->
          {:selected, "Setup selected", "Preparation outcome not recorded.", nil, nil}
      end

    %{kind: kind, label: label, summary: summary, tone: tone, current_step: current_step}
  end

  defp setup_details(turn, session, session_state, worker, workspace) do
    compact_details([
      {"Session", session_state.detail},
      {"Profile", session && session.policy},
      {"Selected from", "Not recorded"},
      {"Worker", worker},
      {"Repository access", workspace.access},
      {"Ryker tools", if(is_binary(turn.state_tools_endpoint), do: "Bound to this work turn")},
      {"Bound task", session && setup_task(session.workspace_task)},
      {"Preparation checks", "Individual check results not recorded"}
    ])
  end

  defp setup_technical(turn, nil, _placement),
    do: compact_details([{"Turn", turn.turn_ref}, {"Work claims", turn.work_attempt_count}])

  defp setup_technical(turn, session, placement) do
    compact_details([
      {"Turn", turn.turn_ref},
      {"Session", session.id},
      {"Session generation", session.generation},
      {"Create generation", session.create_generation},
      {"Remote session", session.coop_session_id},
      {"Remote turn", turn.coop_turn_id},
      {"Policy digest", short_digest(session.policy_digest)},
      {"Authority digest", short_digest(session.authority_digest)},
      {"Repository", session.repository_ref},
      {"Placement worker", placement && placement.worker_id},
      {"Placement generation", placement && placement.generation},
      {"Work claims", turn.work_attempt_count}
    ])
  end

  defp selected_setup(session, placement) do
    %{
      kind: :selected,
      label: "Setup selected",
      summary: "Waiting for a Work claim. Preparation has not started.",
      tone: nil,
      ordinal: nil,
      current_step: nil,
      rows:
        compact_details([
          {"Session", "Not created"},
          {"Profile", session.policy}
        ]),
      details:
        compact_details([
          {"Profile", session.policy},
          {"Selected from", "Not recorded"},
          {"Worker", setup_worker(session, placement)},
          {"Repository", session.repository_ref}
        ]),
      technical:
        compact_details([
          {"Session", session.id},
          {"Session generation", session.generation},
          {"Policy digest", short_digest(session.policy_digest)},
          {"Authority digest", short_digest(session.authority_digest)}
        ])
    }
  end

  # New, reused or replaced is read from generations and earlier turns on the
  # same row. The rotation reason is not retained anywhere, so a replacement
  # says "Reason not recorded" rather than borrowing today's session state.
  defp session_state(nil, _earlier_turns),
    do: %{face: "Not recorded", detail: "Not recorded"}

  defp session_state(session, earlier_turns) do
    cond do
      earlier_turns != [] ->
        %{
          face: "Reused from previous work round",
          detail: "Reused from previous work round · Generation #{session.generation}"
        }

      session.generation > 1 or session.create_generation > 1 ->
        %{
          face: "Replaced · Reason not recorded",
          detail: "Replaced · Generation #{session.generation} · Reason not recorded"
        }

      true ->
        %{face: "New", detail: "New · Generation #{session.generation}"}
    end
  end

  # What the recorded code means, in one sentence. A missing per-worker
  # breakdown stays missing: "no eligible capacity" is not "every worker was
  # busy", and the rows cannot say which it was.
  defp setup_failure("coop_worker_capacity_unavailable"),
    do: "No eligible worker with available capacity was found."

  defp setup_failure(code) when code in ~w(coop_unavailable coop_transport_error),
    do: "The worker connection failed before the session was ready."

  defp setup_failure(nil), do: "Preparation stopped; the recorded error has no code."
  defp setup_failure(code), do: "Preparation stopped: " <> error_label(code) <> "."

  # The repository-backed task this session was pinned for, when there is one.
  # A pinned task is a binding, not proof of a Coop task timeline.
  defp setup_task(%{} = task) do
    title =
      if is_binary(task["title"]),
        do: InspectionRedactor.artifact(task["title"], max_bytes: 200).text

    repository =
      case task do
        %{"repository" => repository} when is_binary(repository) -> repository
        %{"primary" => %{"name" => name}} when is_binary(name) -> name
        _task -> nil
      end

    [title, repository] |> Enum.reject(&is_nil/1) |> Enum.join(" · ") |> present()
  end

  defp setup_task(_task), do: nil

  defp setup_worker(_session, %Placement{worker_id: worker}) when is_binary(worker), do: worker
  defp setup_worker(%Session{coop_session_id: id}, nil) when is_binary(id), do: "Local Coop"
  defp setup_worker(_session, _placement), do: nil

  defp preparing_step(%Session{coop_session_id: nil}, _turn), do: "Creating worker session"
  defp preparing_step(_session, %Turn{submission: nil}), do: "Preparing the briefing"
  defp preparing_step(_session, _turn), do: "Submitting the frozen briefing"

  defp setup_workspace(%Turn{operational_pruned_at: pruned, submission: submission})
       when not is_nil(pruned) or not is_map(submission),
       do: %{face: nil, access: nil}

  defp setup_workspace(%Turn{submission: submission}) do
    case get_in(submission, ["context", "workspace"]) do
      %{"primary" => %{} = primary} = workspace ->
        companions = workspace |> Map.get("companions", []) |> Enum.filter(&is_map/1)
        count = 1 + length(companions)

        %{
          face: "Prepared · #{plural(count, "repository", "repositories")}",
          access: Enum.map_join([primary | companions], " · ", &repository_access/1)
        }

      _absent ->
        %{face: nil, access: nil}
    end
  end

  defp repository_access(%{"name" => name, "read_only" => true}), do: "#{name} read-only"
  defp repository_access(%{"name" => name, "read_only" => false}), do: "#{name} writable"
  defp repository_access(%{"name" => name}), do: "#{name} access not recorded"
  defp repository_access(_repository), do: "unnamed repository"

  defp turn_steps(turns, sessions) do
    sessions_by_id = Map.new(sessions, &{&1.id, &1})

    turns
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {turn, ordinal} ->
      session = Map.get(sessions_by_id, turn.session_id)

      prepared =
        step(
          "turn-#{turn.id}-prepared",
          :ready,
          turn.inserted_at,
          %{
            actor: "Ryker",
            owner: {:turn, turn.id},
            details:
              compact_details([
                {"Turn", turn.turn_ref},
                {"Policy", session && session.policy},
                {"Repository", session && session.repository_ref}
              ]),
            stage: "Routing",
            state: "",
            summary: "The new input was queued for model work.",
            title: "Turn #{ordinal} queued",
            tone: nil
          }
        )

      work = work_step(turn, ordinal)
      answer = answer_steps(turn, ordinal)
      outcome = delivery_step(turn, ordinal)

      ([prepared, work] ++ answer ++ outcome)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp work_step(%Turn{remote_finished_at: nil}, _ordinal), do: nil

  defp work_step(turn, ordinal) do
    step(
      "turn-#{turn.id}-work",
      :work,
      turn.remote_finished_at || turn.remote_started_at,
      %{
        actor: "Coop",
        owner: {:turn, turn.id},
        details:
          compact_details([
            {"Target", turn.execution_target},
            {"Queued", format_ms(turn.usage_queued_ms)},
            {"Provider", format_ms(turn.usage_provider_ms)},
            {"Host", format_ms(turn.usage_host_ms)},
            {"Work claims", turn.work_attempt_count},
            {"Remote operation", turn.remote_operation_kind},
            {"Measurement", turn.measurement_error_code || measurement_state(turn)}
          ]),
        duration_ms: turn.usage_provider_ms,
        stage: "Execution",
        state: work_state(turn),
        summary: work_summary(turn),
        title: "Turn #{ordinal} finished",
        tone: state_tone(work_state(turn))
      }
    )
  end

  defp answer_steps(turn, ordinal) do
    validations = validation_steps(turn, ordinal)
    accepted = accepted_step(turn, ordinal)
    validations ++ Enum.reject([accepted], &is_nil/1)
  end

  defp validation_steps(%Turn{validation_history: history} = turn, ordinal)
       when is_list(history) and history != [] do
    Enum.map(history, &validation_history_step(turn, ordinal, &1))
  end

  defp validation_steps(%Turn{validation_intent: nil, candidate_attempt: nil}, _ordinal), do: []

  defp validation_steps(turn, ordinal), do: [validation_step(turn, ordinal)]

  defp validation_band(nil, _at), do: :work
  defp validation_band(_finished_at, nil), do: :answer

  defp validation_band(finished_at, at),
    do: if(DateTime.compare(at, finished_at) == :lt, do: :work, else: :answer)

  defp validation_history_step(turn, ordinal, entry) do
    verdict = entry["verdict"]
    violations = bounded_strings(entry["violations"])
    attempt = entry["candidate_attempt"]
    at = parsed_time(entry["recorded_at"])

    validation_step(turn, ordinal,
      at: at,
      attempt: attempt,
      candidate_sha256: entry["candidate_sha256"],
      intent_fingerprint: entry["intent_fingerprint"],
      parse: entry["parse"],
      receipt: nil,
      response_bytes: entry["response_bytes"],
      verdict: verdict,
      violations: violations
    )
  end

  defp validation_step(turn, ordinal) do
    verdict = get_in(turn.validation_intent || %{}, ["verdict"])
    violations = bounded_strings(get_in(turn.validation_intent || %{}, ["violations"]))

    validation_step(turn, ordinal,
      at: nil,
      attempt: turn.candidate_attempt,
      candidate_sha256: turn.candidate_sha256,
      intent_fingerprint: turn.validation_intent_fingerprint,
      parse: candidate_parse(turn.candidate),
      receipt: turn.validation_receipt,
      response_bytes: if(is_binary(turn.candidate), do: byte_size(turn.candidate)),
      verdict: verdict,
      violations: violations
    )
  end

  defp validation_step(turn, ordinal, options) do
    verdict = Keyword.fetch!(options, :verdict)
    violations = Keyword.fetch!(options, :violations)
    attempt = Keyword.fetch!(options, :attempt)
    state = verdict || "candidate recorded"

    {title, tone} = validation_presentation(verdict)

    step(
      "turn-#{turn.id}-validation-#{attempt || 0}",
      validation_band(turn.remote_finished_at, Keyword.fetch!(options, :at)),
      Keyword.fetch!(options, :at),
      %{
        actor: "Ryker",
        owner: {:turn, turn.id},
        details:
          compact_details([
            {"Turn", ordinal},
            {"Candidate attempt", attempt},
            {"Response bytes", Keyword.fetch!(options, :response_bytes)},
            {"Parse", Keyword.fetch!(options, :parse)},
            {"Verdict", verdict},
            {"Violations", Enum.join(violations, " · ")},
            {"Result", if(verdict == "accept", do: "Passed the response checks")}
          ]),
        stage: "Validation",
        state: state,
        summary: validation_summary(verdict, violations, turn),
        title: title,
        tone: tone
      }
    )
  end

  defp validation_presentation("reject"), do: {"Answer rejected", :bad}
  defp validation_presentation("accept"), do: {"Answer validated", :good}
  defp validation_presentation(_), do: {"Response recorded", nil}

  defp accepted_step(%Turn{accepted_at: nil}, _ordinal), do: nil

  defp accepted_step(turn, ordinal) do
    step(
      "turn-#{turn.id}-accepted",
      :answer,
      turn.accepted_at,
      %{
        actor: "Ryker",
        owner: {:turn, turn.id},
        result_ref: turn.result_ref,
        details:
          compact_details([
            {"Result", turn.result_ref},
            {"Delivery", delivery_kind(turn.delivery_document)},
            {"Artifacts", outcome_count(turn.delivery_document, "artifact_refs")},
            {"Records", outcome_count(turn.delivery_document, "record_refs")},
            {"Outcome", get_in(turn.delivery_document || %{}, ["outcome", "state"])}
          ]),
        stage: "Result",
        state: "accepted",
        summary: delivery_summary(turn.delivery_document),
        title: "Turn #{ordinal} result accepted",
        tone: :good
      }
    )
  end

  defp delivery_step(
         %Turn{delivery_ref: nil, delivered_at: nil, external_receipt: nil},
         _ordinal
       ),
       do: []

  defp delivery_step(turn, ordinal) do
    queued =
      step(
        "turn-#{turn.id}-delivery-queued",
        :outcome,
        turn.accepted_at,
        %{
          actor: "Ryker",
          owner: {:turn, turn.id},
          delivery_ref: turn.delivery_ref,
          details: compact_details([{"Turn", ordinal}]),
          stage: "Delivery",
          state: "queued",
          summary: "The accepted response was queued for delivery.",
          title: "Response queued for delivery",
          tone: nil
        }
      )

    [queued | confirmed_delivery_step(turn, ordinal)]
  end

  defp confirmed_delivery_step(%Turn{delivered_at: nil}, _ordinal), do: []

  defp confirmed_delivery_step(turn, ordinal) do
    [
      step(
        "turn-#{turn.id}-delivery-confirmed",
        :outcome,
        turn.delivered_at,
        %{
          actor: delivery_actor(turn.external_receipt),
          owner: {:turn, turn.id},
          delivery_ref: turn.delivery_ref,
          details:
            compact_details([
              {"Turn", ordinal},
              {"Delivery", turn.delivery_ref},
              {"Transport", get_in(turn.external_receipt || %{}, ["transport"])},
              {"Message", get_in(turn.external_receipt || %{}, ["message_ref"])}
            ]),
          stage: "Delivery",
          state: "delivered",
          summary: delivery_confirmation(turn.external_receipt),
          title: "Delivery confirmed",
          tone: :good
        }
      )
    ]
  end

  defp record_steps(records) do
    records
    |> Enum.with_index(1)
    |> Enum.map(fn {record, index} ->
      card =
        case Card.project(%{
               record
               | status: :open,
                 updated_at: record.inserted_at,
                 wait_error: nil
             }) do
          {:ok, projected} -> projected
          :ignore -> nil
        end

      step(
        "record-#{record.id || index}",
        record_band(record.kind),
        record.inserted_at,
        %{
          actor: "Ryker state",
          record_ref: record.ref,
          details: compact_details(record_details(record, card)),
          href: record_href(record),
          stage: record_stage(record.kind),
          state: "",
          summary: record_summary(record, card),
          title: record_title(record, card),
          current_warning: Card.wait_warning(record),
          tone: nil
        }
      )
    end)
  end

  defp coop_steps([]), do: []

  defp coop_steps(sessions) do
    session_ids = Enum.map(sessions, & &1.id)

    Repo.all(
      from(event in CoopEvent,
        where: event.session_id in ^session_ids and event.kind != "session_event",
        order_by: [asc: event.inserted_at, asc: event.sequence],
        limit: 500
      )
    )
    |> Enum.map(fn event ->
      step(
        "coop-event-#{event.id}",
        coop_band(event.kind),
        event.inserted_at,
        %{
          actor: "Coop fleet",
          details:
            compact_details([
              {"Worker", event.worker_id},
              {"Placement generation", event.placement_generation},
              {"Sequence", event.sequence},
              {"Event", event.kind},
              {"Payload", short_digest(event.payload_fingerprint)}
            ]),
          stage: "Worker",
          state: event.kind,
          summary: coop_summary(event.payload),
          title: coop_title(event.kind),
          tone: coop_tone(event.kind)
        }
      )
    end)
  end

  defp activity_steps(activity_events, causality, disclosed) do
    routing_ids =
      activity_events
      |> Enum.filter(&(not is_nil(&1.admission_input_id)))
      |> Enum.map(&("activity-" <> &1.id))
      |> MapSet.new()

    activity_events
    |> Enum.reject(&(&1.kind == "model.thought"))
    |> Enum.reduce({[], %{}}, &fold_activity(&1, &2, disclosed))
    |> elem(0)
    |> Enum.map(fn step ->
      step = %{step | owner: activity_step_owner(step.id, causality)}
      if MapSet.member?(routing_ids, step.id), do: %{step | band: :routing}, else: step
    end)
  end

  # The remote turn id on the event is the durable link back to this episode's
  # Work turn; a tool result is owned by the turn that called it, not by
  # whatever message happens to precede it in the reader's scroll.
  defp activity_step_owner("activity-" <> event_id, causality),
    do: EpisodeCausality.activity_owner(causality, event_id)

  defp activity_step_owner(_id, _causality), do: :episode

  defp fold_activity(%ActivityEvent{kind: "tool.started"} = event, {steps, open}, disclosed) do
    key = activity_tool_key(event)
    activity_step = tool_started_step(event, disclosed)
    {steps ++ [activity_step], Map.put(open, key, length(steps))}
  end

  defp fold_activity(%ActivityEvent{kind: "tool.completed"} = event, {steps, open}, disclosed) do
    key = activity_tool_key(event)

    case Map.pop(open, key) do
      {nil, open} -> {steps ++ [tool_completed_step(event, disclosed)], open}
      {index, open} -> {steps ++ [complete_tool(Enum.at(steps, index), event, disclosed)], open}
    end
  end

  defp fold_activity(event, {steps, open}, disclosed),
    do: {steps ++ [activity_step(event, disclosed)], open}

  defp tool_started_step(event, disclosed) do
    input = event.payload["input"]

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event, disclosed),
        details:
          compact_details(
            [
              {"Kind", event.payload["kind"]},
              {"Tool call", event.payload["tool_call_id"]}
            ] ++ activity_tool_details(input)
          ),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: "started",
        summary: activity_tool_summary(input),
        title: activity_tool_title(event.payload),
        tone: nil
      }
    )
  end

  defp tool_completed_step(event, disclosed) do
    status = event.payload["status"] || "completed"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        artifacts: tool_artifacts(event, disclosed),
        details:
          compact_details([
            {"Kind", event.payload["kind"]},
            {"Tool call", event.payload["tool_call_id"]},
            {"Status", status}
          ]),
        stage: "Tool call",
        tool_kind: event.payload["kind"],
        path_context: safe_path_context(event.payload["path_context"]),
        state: status,
        summary: tool_outcome(event.payload, status),
        title: event.payload["title"] || "Tool completion recorded",
        tone: activity_status_tone(status)
      }
    )
  end

  defp complete_tool(step, event, disclosed) do
    status = event.payload["status"] || "completed"
    duration_ms = nonnegative_diff(event.occurred_at, step.at)

    %{
      step
      | id: "activity-#{event.id}",
        at: event.occurred_at,
        artifacts: merge_artifacts(step[:artifacts] || [], tool_artifacts(event, disclosed)),
        tool_kind: event.payload["kind"] || step.tool_kind,
        path_context: safe_path_context(event.payload["path_context"] || step.path_context),
        summary: tool_outcome(event.payload, status),
        details:
          step.details ++
            compact_details([
              {"Status", status},
              {"Finished", event.occurred_at}
            ]),
        duration_ms: duration_ms,
        state: human(status),
        tone: activity_status_tone(status)
    }
  end

  defp safe_path_context(value) do
    with %{} = paths <- ActivityPaths.sanitize(value),
         %{text: text, truncated: false} <- InspectionRedactor.artifact(paths, max_bytes: 16_384),
         {:ok, redacted} <- Jason.decode(text) do
      ActivityPaths.sanitize(redacted)
    else
      _ -> nil
    end
  end

  defp activity_step(%ActivityEvent{kind: "model.progress"} = event, _disclosed) do
    step("activity-#{event.id}", :work, event.occurred_at, %{
      actor: "Model",
      details: [],
      stage: "Progress",
      state: "",
      summary: event.payload["text"],
      title: "Progress update"
    })
  end

  defp activity_step(%ActivityEvent{kind: "model.plan"} = event, disclosed) do
    count = event.payload["step_count"] || 0

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Model",
        artifacts: plan_artifacts(event, disclosed),
        details: compact_details([{"Plan steps", count}]),
        stage: "Plan",
        state: "updated",
        summary: plural(count, "plan step"),
        title: "Model plan updated",
        tone: nil
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "permission.decided"} = event, _disclosed) do
    outcome = event.payload["outcome"] || "recorded"

    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop policy",
        details:
          compact_details([
            {"Tool call", event.payload["tool_call_id"]},
            {"Option", event.payload["option_kind"]}
          ]),
        stage: "Permission",
        state: outcome,
        summary: permission_summary(event.payload),
        title: "Tool permission decided",
        tone: activity_status_tone(outcome)
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "activity.elided"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: compact_details([{"Dropped events", event.payload["dropped"]}]),
        stage: "Recorder",
        state: "bounded",
        summary: "The turn exceeded its bounded narration budget.",
        title: "Some activity was elided",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.backoff"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        summary: provider_backoff_summary(event.payload),
        title: "Provider rate limit",
        tone: :warn
      }
    )
  end

  defp activity_step(%ActivityEvent{kind: "provider.alive"} = event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: safe_payload_details(event.payload),
        stage: "Provider",
        summary: provider_alive_summary(event.payload),
        title: "Provider is still responding",
        tone: nil
      }
    )
  end

  defp activity_step(event, _disclosed) do
    step(
      "activity-#{event.id}",
      :work,
      event.occurred_at,
      %{
        actor: "Coop",
        details: [],
        stage: "Worker activity",
        state: "recorded",
        summary: "Bounded activity event recorded.",
        title: capitalize(human(event.kind)),
        tone: nil
      }
    )
  end

  # Tool evidence is the heaviest thing on a long timeline: a tool-heavy run has
  # hundreds of calls, and each one sanitized and re-encoded up to 20 KiB per
  # result field on every refresh, for text that is almost always closed. The
  # result bodies now carry a durable id and load when their disclosure opens.
  #
  # Arguments stay prepared. The compact card face is derived from them -- the
  # command it ran, the file it read, the observation it recorded -- so making
  # them lazy would empty the row a reader scans instead of the body they open.
  @lazy_tool_fields ~w(output error content locations)

  defp tool_artifacts(%ActivityEvent{payload: payload, id: event_id}, disclosed) do
    for {key, label} <- [
          {"input", "Arguments"},
          {"output", "Response"},
          {"error", "Error"},
          {"content", "Output and changes"},
          {"locations", "Files"}
        ],
        Map.has_key?(payload, key),
        payload[key] != nil do
      artifact_id = "activity-#{event_id}-#{key}"
      lazy? = key in @lazy_tool_fields

      %{
        label: label,
        artifact_id: if(lazy?, do: artifact_id),
        artifact:
          InspectionRedactor.artifact(payload[key],
            max_bytes: 20_000,
            disclosed: not lazy? or MapSet.member?(disclosed, artifact_id)
          )
      }
    end
  end

  defp plan_artifacts(%ActivityEvent{payload: %{"entries" => entries}, id: id}, disclosed)
       when entries not in [nil, []] do
    artifact_id = "activity-#{id}-plan"

    [
      %{
        label: "Plan",
        artifact_id: artifact_id,
        artifact:
          InspectionRedactor.artifact(entries,
            max_bytes: 20_000,
            disclosed: MapSet.member?(disclosed, artifact_id)
          )
      }
    ]
  end

  defp plan_artifacts(_event, _disclosed), do: []

  defp merge_artifacts(start, finish),
    do:
      Enum.reject(start, fn artifact -> Enum.any?(finish, &(&1.label == artifact.label)) end) ++
        finish

  defp tool_outcome(payload, "failed") do
    case payload["error"] || payload["output"] || payload["content"] do
      nil -> "The tool failed. Its error response was not recorded for this older call."
      value -> value |> InspectionRedactor.artifact(max_bytes: 300) |> Map.fetch!(:text)
    end
  end

  defp tool_outcome(_payload, "cancelled"), do: "The tool call was cancelled."
  defp tool_outcome(_payload, _status), do: nil

  defp activity_tool_key(event),
    do:
      {event.session_id, event.coop_turn_id,
       event.payload["tool_call_id"] || event.remote_event_id}

  defp activity_tool_title(%{
         "input" => %{"operation" => action, "server" => server}
       })
       when is_binary(server) and is_binary(action),
       do: "#{server} · #{action}"

  defp activity_tool_title(%{"title" => title}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 200).text

  defp activity_tool_title(_payload), do: "Tool call"

  defp activity_tool_summary(%{} = input) do
    [input["server"], input["operation"] || input["tool"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> present()
  end

  defp activity_tool_summary(_input), do: "Tool execution recorded."

  defp activity_tool_details(input) when is_map(input) do
    [
      {"Server", input["server"]},
      {"Tool", input["tool"]},
      {"Operation", input["operation"]}
    ]
  end

  defp activity_tool_details(_input), do: []

  defp safe_payload_details(payload), do: payload |> safe_fields() |> compact_details()

  defp safe_fields(%{} = fields) do
    fields
    |> Enum.reject(fn {key, _value} -> sensitive_key?(key) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} ->
      case safe_activity_value(value) do
        nil -> []
        safe -> [{capitalize(human(key)), safe}]
      end
    end)
    |> Enum.take(20)
  end

  defp safe_fields(_fields), do: []

  defp safe_activity_value(value) when is_binary(value), do: value |> scrub_url() |> bounded(512)

  defp safe_activity_value(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: to_string(value)

  defp safe_activity_value(value) when is_map(value) or is_list(value) do
    value
    |> redact_activity_value()
    |> CanonicalJSON.encode!()
    |> bounded(512)
  rescue
    ArgumentError -> nil
  end

  defp safe_activity_value(_value), do: nil

  defp redact_activity_value(%{} = value) do
    value
    |> Enum.reject(fn {key, _nested} -> sensitive_key?(key) end)
    |> Map.new(fn {key, nested} -> {to_string(key), redact_activity_value(nested)} end)
  end

  defp redact_activity_value(value) when is_list(value),
    do: value |> Enum.take(32) |> Enum.map(&redact_activity_value/1)

  defp redact_activity_value(value) when is_binary(value), do: scrub_url(value)
  defp redact_activity_value(value), do: value

  defp sensitive_key?(key) when is_atom(key) or is_binary(key),
    do:
      Regex.match?(~r/(?:authorization|cookie|credential|password|secret|token)/i, to_string(key))

  defp sensitive_key?(_key), do: false

  defp scrub_url(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        uri |> Map.merge(%{fragment: nil, query: nil, userinfo: nil}) |> URI.to_string()

      _not_url ->
        value
    end
  end

  defp permission_summary(payload) do
    case payload["outcome"] do
      "cancelled" -> "Coop policy refused this unattended permission request."
      outcome when is_binary(outcome) -> "Coop policy recorded #{human(outcome)}."
      _missing -> "Coop policy recorded a permission decision."
    end
  end

  # The step used to say only which provider was limited, over a badge that
  # repeated the title. What a reader needs is where the work goes instead.
  defp provider_backoff_summary(payload) do
    target = payload["target"] || payload["provider"]
    next_target = payload["next_target"]
    reset = payload["reset_at"] || payload["retry_after"] || retry_in(payload)

    [limited(target), replacement(next_target), fallback_retry(next_target, reset)]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
    |> case do
      "" -> "Coop paused this turn at the provider's rate limit."
      summary -> summary <> "."
    end
  end

  defp limited(nil), do: nil
  defp limited(target), do: "#{target} is rate limited"

  defp replacement(nil), do: nil
  defp replacement(next_target), do: "#{next_target} will be used instead"

  defp fallback_retry(nil, reset) when is_binary(reset), do: "retrying #{reset}"
  defp fallback_retry(_next_target, _reset), do: nil

  defp retry_in(%{"retry_after_seconds" => seconds}) when is_integer(seconds),
    do: "in #{seconds}s"

  defp retry_in(_payload), do: nil

  defp provider_alive_summary(payload) do
    frames = payload["frames"]
    bytes = payload["bytes"]

    [frames && "#{frames} frames", bytes && "#{bytes} bytes observed"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "Provider frames are still arriving although no higher-level activity was narrated."
      summary -> summary
    end
  end

  defp activity_status_tone(status) when status in ["failed", "denied"], do: :bad
  defp activity_status_tone(status) when status in ["cancelled", "backing off"], do: :warn
  defp activity_status_tone(status) when status in ["completed", "selected", "allowed"], do: :good
  defp activity_status_tone(_status), do: nil

  defp nonnegative_diff(%DateTime{} = right, %DateTime{} = left),
    do: max(DateTime.diff(right, left, :millisecond), 0)

  defp nonnegative_diff(_right, _left), do: nil

  defp platform_actions(episode_id) do
    Repo.all(
      from(action in PlatformAction,
        where: action.episode_id == ^episode_id,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: 200
      )
    )
  end

  defp platform_action_steps(actions) do
    Enum.flat_map(actions, fn action ->
      queued =
        step(
          "platform-action-#{action.id}",
          :outcome,
          action.inserted_at,
          %{
            actor: action.transport,
            details:
              compact_details([
                {"Action", action.action_ref},
                {"Conversation", action.conversation_ref},
                {"Thread", action.thread_ref}
              ]),
            stage: "Platform action",
            state: "queued",
            summary: "Queued for #{capitalize(action.transport)} delivery.",
            title: platform_action_title(action.tool),
            tone: nil
          }
        )

      if action.delivered_at do
        [
          queued,
          step("platform-action-#{action.id}-confirmed", :outcome, action.delivered_at, %{
            actor: action.transport,
            details: [],
            stage: "Platform action",
            state: "confirmed",
            title: platform_action_title(action.tool) <> " confirmed",
            summary: "#{capitalize(action.transport)} confirmed the action.",
            tone: :good
          })
        ]
      else
        [queued]
      end
    end)
  end

  defp incident_steps(episode_id) do
    Repo.all(
      from(room in IncidentRoom,
        where: room.episode_id == ^episode_id or room.source_episode_id == ^episode_id,
        order_by: [asc: room.requested_at, asc: room.id],
        limit: 50
      )
    )
    |> Enum.map(fn room ->
      step(
        "incident-#{room.id}",
        :outcome,
        room.requested_at || room.inserted_at,
        %{
          actor: "Ryker",
          details:
            compact_details([
              {"Incident room", room.ref},
              {"Repository", room.repository_ref}
            ]),
          href: "/incident-rooms/#{segment(room.ref)}",
          stage: "Incident",
          state: nil,
          summary: "An incident room was requested. Open the room for its current state.",
          title: "Incident room requested",
          tone: nil
        }
      )
    end)
  end

  defp publications(episode_id) do
    Repo.all(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [asc: publication.inserted_at, asc: publication.id],
        limit: 50
      )
    )
  end

  defp publication_steps(publications) do
    Enum.flat_map(publications, fn publication ->
      requested =
        step(
          "publication-#{publication.id}",
          :outcome,
          publication.inserted_at,
          %{
            actor: "Ryker",
            details:
              compact_details([
                {"Publication", publication.ref},
                {"Repository", publication.repository}
              ]),
            stage: "Publication",
            state: nil,
            summary: "Changes were offered for review before publication.",
            title: "Publication requested",
            tone: nil
          }
        )

      if publication.published_at do
        [
          requested,
          step("publication-#{publication.id}-published", :outcome, publication.published_at, %{
            actor: "Ryker",
            stage: "Publication",
            state: nil,
            title: "Draft pull request published",
            summary: "Pull request ##{publication.pull_request_number}",
            details:
              compact_details([
                {"Repository", publication.repository},
                {"Branch", publication.branch_ref},
                {"Commit", publication.commit_sha}
              ]),
            tone: :good
          })
        ]
      else
        [requested]
      end
    end)
  end

  # Current follow-through is deliberately outside historical timeline events.
  # Retrying may change this status; it must not rewrite the original request.
  defp follow_through(actions, publications, source) do
    action_status =
      for action <- actions,
          action.status != :delivered,
          action.status == :blocked or not is_nil(action.last_error_code) do
        %{
          id: "platform-action-#{action.id}",
          title: platform_action_title(action.tool),
          state: capitalize(human(action.status)),
          error: InspectionRedactor.artifact(action.last_error_code).text,
          href:
            if(action.status == :blocked, do: "/failures/delivery/#{segment(action.action_ref)}"),
          link_label: "Open recovery"
        }
      end

    publication_status =
      for publication <- publications, publication.status != :published do
        %{
          id: "publication-#{publication.id}",
          title: InspectionRedactor.artifact(publication.title).text,
          state: capitalize(human(publication.status)),
          error: InspectionRedactor.artifact(publication.last_error_code).text,
          href: if(source, do: source.href),
          link_label: "Open conversation"
        }
      end

    action_status ++ publication_status
  end

  defp schedule_steps(episode_id) do
    Repo.all(
      from(schedule in Schedule,
        where: schedule.source_episode_id == ^episode_id,
        order_by: [asc: schedule.confirmed_at, asc: schedule.id],
        limit: 50
      )
    )
    |> Enum.map(fn schedule ->
      step(
        "schedule-#{schedule.id}",
        :outcome,
        schedule.confirmed_at || schedule.inserted_at,
        %{
          actor: "Ryker",
          details:
            compact_details([
              {"Schedule", schedule.ref}
            ]),
          href: "/schedules/#{segment(schedule.ref)}",
          stage: "Schedule",
          state: nil,
          summary: "A schedule was created. Open it for its configuration and next run.",
          title: "Schedule created",
          tone: nil
        }
      )
    end)
  end

  # Learning is a peer of the work, not a step inside it: it runs on decided
  # inputs whether or not this episode ever replied. A batch appears here only
  # when one of this episode's own inputs is a recorded member of it, never
  # because it shares a channel, and a cross-episode batch says how much of it
  # belongs here rather than borrowing the rest.
  defp learning_steps([]), do: []

  defp learning_steps(input_rows) do
    input_ids = Enum.map(input_rows, & &1.id)

    memberships =
      Repo.all(
        from(membership in InputMembership,
          where: membership.input_id in ^input_ids,
          select: {membership.batch_id, membership.input_id}
        )
      )

    local_counts =
      memberships
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {batch, rows} -> {batch, length(rows)} end)

    batch_ids = Map.keys(local_counts)

    if batch_ids == [] do
      []
    else
      Repo.all(
        from(run in LearningRun,
          where: run.batch_id in ^batch_ids,
          order_by: [asc: run.inserted_at, asc: run.id],
          limit: 50
        )
      )
      |> Enum.map(&learning_step(&1, Map.get(local_counts, &1.batch_id, 0)))
    end
  end

  defp learning_step(run, local_inputs) do
    outcome = learning_outcome(run)
    total_inputs = length(List.wrap(run.inputs))

    step("learning-#{run.id}", :learning, run.applied_at || run.inserted_at, %{
      actor: "Ryker",
      stage: "Learning",
      state: outcome.label,
      title: "Learning",
      summary: outcome.summary,
      tone: outcome.tone,
      href: LearningActivity.attempt_path(run.batch_id, run.id),
      details:
        compact_details([
          {"Messages read", learning_membership(total_inputs, local_inputs)},
          {"Model", get_in(run.producer || %{}, ["target"]) || "Not recorded"},
          {"Prompt", if(run.prompt_sha256, do: short_digest(run.prompt_sha256))},
          {"Result", if(run.result_sha256, do: short_digest(run.result_sha256))},
          {"Outcome", outcome.detail},
          {"Applied", run.applied_at},
          {"Bodies", if(run.pruned_at, do: "Expired #{timestamp_precise(run.pruned_at)}")}
        ])
    })
  end

  # A batch can read inputs from several episodes. Saying "3 messages" when one
  # of them is this episode's would credit this page with another one's sources.
  defp learning_membership(total, local) when total > local,
    do: "#{local} of #{total} from this request"

  defp learning_membership(total, _local), do: plural(total, "message")

  defp learning_outcome(%LearningRun{status: :applied, result: result}) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"updates" => updates}} when is_list(updates) ->
        {deferred, saved} = Enum.split_with(updates, &match?(%{"action" => "defer"}, &1))

        cond do
          saved == [] and deferred == [] ->
            %{
              label: "no change",
              summary: "Nothing new to save from these messages.",
              tone: nil,
              detail: "Empty result"
            }

          saved == [] ->
            %{
              label: "deferred",
              summary: "The model deferred every judgment; nothing was saved.",
              tone: nil,
              detail: "#{length(deferred)} deferred"
            }

          true ->
            %{
              label: "knowledge saved",
              summary: "Saved #{plural(length(saved), "topic update")} from these messages.",
              tone: :good,
              detail: "#{length(saved)} saved · #{length(deferred)} deferred"
            }
        end

      _unreadable ->
        %{label: "applied", summary: "The learning result was applied.", tone: :good, detail: nil}
    end
  end

  defp learning_outcome(%LearningRun{status: :applied}),
    do: %{label: "applied", summary: "The learning result was applied.", tone: :good, detail: nil}

  defp learning_outcome(%LearningRun{status: :rejected, error_code: code}),
    do: %{
      label: "rejected",
      summary: "The host rejected this learning result. Nothing was saved.",
      tone: :warn,
      detail: error_label(code)
    }

  defp learning_outcome(%LearningRun{status: :stale, error_code: code}),
    do: %{
      label: "stale",
      summary: "The sources or the target topic changed before this result could be applied.",
      tone: :warn,
      detail: error_label(code)
    }

  defp learning_outcome(%LearningRun{status: status, error_code: code}),
    do: %{
      label: human(status),
      summary: "A learning pass read these messages. It sent no reply.",
      tone: nil,
      detail: error_label(code)
    }

  # Cleanup is what happened to the temporary session and workspace, at its own
  # time. Closing is not removing, a kept workspace is not a failure, and a
  # local session that never bound a remote one had nothing to delete.
  defp maintenance_steps(sessions) do
    sessions
    |> Enum.filter(&(&1.cleanup_status != :active))
    |> Enum.flat_map(fn session ->
      closed =
        if session.closed_at do
          [
            step("maintenance-#{session.id}-closed", :maintenance, session.closed_at, %{
              actor: "Ryker",
              stage: "Maintenance",
              state: "session closed",
              title: "Session closed",
              summary: cleanup_repository(session),
              tone: nil,
              details:
                compact_details([
                  {"Repository", session.repository_ref},
                  {"Cleanup eligible after", session.discard_after},
                  {"Session", session.coop_session_id || "No remote session was bound"}
                ])
            })
          ]
        else
          []
        end

      closed ++ cleanup_outcome_step(session)
    end)
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :discarded} = session) do
    [
      step("maintenance-#{session.id}-discarded", :maintenance, session.discarded_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "workspace removed",
        title: "Workspace removed",
        summary: cleanup_receipt_summary(session),
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Receipt", get_in(session.cleanup_receipt || %{}, ["outcome"])},
            {"Session", session.coop_session_id}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :retained} = session) do
    [
      step("maintenance-#{session.id}-retained", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "workspace kept",
        title: "Workspace kept",
        summary: retained_reason(session.retained_reason),
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Reason", session.retained_reason},
            {"Session", session.coop_session_id}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :blocked} = session) do
    [
      step("maintenance-#{session.id}-blocked", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "cleanup blocked",
        title: "Cleanup blocked",
        summary:
          "Cleanup stopped and needs attention. The delivered answer is unaffected." <>
            queue_error_sentence(session.cleanup_last_error_code),
        tone: :warn,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Blocked from", session.cleanup_blocked_from},
            {"Attempts", session.cleanup_attempt_count},
            {"Next attempt", session.cleanup_next_attempt_at}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(_session), do: []

  defp cleanup_repository(%Session{repository_ref: nil}),
    do: "The worker session was closed. No repository working copy was bound to it."

  defp cleanup_repository(%Session{repository_ref: repository}),
    do: "#{repository}'s worker session was closed. Closing is not removing its workspace."

  defp cleanup_receipt_summary(%Session{cleanup_receipt: %{"outcome" => "never_bound"}}),
    do: "No remote session was ever bound, so there was no remote workspace to delete."

  defp cleanup_receipt_summary(%Session{cleanup_receipt: %{"outcome" => "already_discarded"}}),
    do:
      "The worker reported the workspace was already gone; this pass observed that, it did not delete it."

  defp cleanup_receipt_summary(_session),
    do: "The temporary workspace was discarded. Retained inspection evidence is unaffected."

  defp retained_reason("dirty" <> _),
    do: "The workspace was kept: it still holds uncommitted changes."

  defp retained_reason("unmerged" <> _),
    do: "The workspace was kept: it still holds commits that were never published."

  defp retained_reason(nil), do: "The workspace was kept. No reason was recorded."
  defp retained_reason(reason), do: "The workspace was kept: " <> human(reason) <> "."

  defp totals(episode_id, events, records, sessions, turns) do
    turn_totals =
      Repo.one!(
        from(turn in Turn,
          where: turn.episode_id == ^episode_id,
          select: %{
            cost:
              type(
                fragment(
                  "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) ELSE 0 END), 0)",
                  turn.usage_cost_recorded,
                  turn.usage_cost_usd
                ),
                :decimal
              ),
            costed:
              type(
                fragment("COUNT(*) FILTER (WHERE ?)::bigint", turn.usage_cost_recorded),
                :integer
              ),
            measured:
              type(
                fragment("COUNT(*) FILTER (WHERE ?)::bigint", turn.usage_recorded),
                :integer
              ),
            repairs:
              type(
                fragment(
                  "COALESCE(SUM(GREATEST(COALESCE(?, 1) - 1, 0)), 0)::bigint",
                  turn.candidate_attempt
                ),
                :integer
              ),
            tokens:
              type(
                fragment(
                  "COALESCE(SUM(CASE WHEN ? THEN COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) ELSE 0 END), 0)::bigint",
                  turn.usage_recorded,
                  turn.usage_input_tokens,
                  turn.usage_cached_input_tokens,
                  turn.usage_output_tokens,
                  turn.usage_reasoning_tokens
                ),
                :integer
              ),
            turns: count(turn.id),
            work_claims:
              type(
                fragment("COALESCE(SUM(?), 0)::bigint", turn.work_attempt_count),
                :integer
              )
          }
        )
      )

    Map.merge(turn_totals, %{
      current_turn: List.last(turns),
      events:
        Repo.aggregate(from(event in Event, where: event.episode_id == ^episode_id), :count),
      events_shown: length(events),
      records:
        Repo.aggregate(from(record in Record, where: record.episode_id == ^episode_id), :count),
      records_shown: length(records),
      sessions:
        Repo.aggregate(from(session in Session, where: session.episode_id == ^episode_id), :count),
      sessions_shown: length(sessions),
      turns_shown: length(turns)
    })
  end

  defp history(totals, activity_page) do
    windows = [
      history_window("kernel events", totals.events_shown, totals.events),
      history_window("records", totals.records_shown, totals.records),
      history_window("sessions", totals.sessions_shown, totals.sessions),
      history_window("turns", totals.turns_shown, totals.turns),
      history_window("activity events", activity_page.shown, activity_page.total)
    ]

    %{truncated: Enum.any?(windows, & &1.truncated), windows: windows}
  end

  defp history_window(label, shown, total),
    do: %{label: label, shown: shown, total: total, truncated: total > shown}

  defp latest_time(steps, fallback) do
    Enum.reduce(steps, fallback, fn
      %{at: %DateTime{} = at}, %DateTime{} = latest ->
        if DateTime.compare(at, latest) == :gt, do: at, else: latest

      _step, latest ->
        latest
    end)
  end

  defp metrics(episode, received_at, activity_page, totals, steps) do
    [
      metric(
        "State",
        human(episode.state),
        next_action(episode, totals.current_turn),
        state_tone(episode.state)
      ),
      metric(
        "Elapsed",
        elapsed(received_at, latest_time(steps, episode.updated_at)),
        "first input to latest change"
      ),
      metric("Turns", totals.turns, plural(totals.work_claims, "Work claim")),
      metric(
        "Repairs",
        totals.repairs,
        "candidate corrections",
        if(totals.repairs > 0, do: :warn, else: nil)
      ),
      metric(
        "Tokens",
        if(totals.measured == 0, do: "unmeasured", else: format_integer(totals.tokens)),
        "#{totals.measured}/#{totals.turns} measured"
      ),
      metric(
        "Cost",
        if(totals.costed == 0,
          do: "unmeasured",
          else: "$" <> Decimal.to_string(totals.cost, :normal)
        ),
        "#{totals.costed}/#{totals.turns} costed"
      ),
      metric(
        "Tool calls",
        activity_page.tool_calls,
        "durably narrated by Coop"
      ),
      metric("Records", totals.records, "durable state records")
    ]
  end

  defp stats(steps, activity_page, totals) do
    [
      %{label: "steps shown", value: length(steps)},
      %{label: "turns", value: totals.turns},
      %{label: "records", value: totals.records},
      %{label: "activity", value: activity_page.total}
    ]
  end

  defp stopped(%Episode{state: :waiting_for_input}, _turn) do
    %{
      action: "Reply in the bound conversation",
      attempted: [],
      headline: "Waiting for a person",
      href: nil,
      reason: "The model recorded a material question and released its worker lease."
    }
  end

  defp stopped(%Episode{state: :waiting_for_event}, _turn) do
    %{
      action: "Wait for the recorded event or deadline",
      attempted: [],
      headline: "Waiting for an external event",
      href: nil,
      reason: "The episode is parked durably and will resume only for its bound trigger."
    }
  end

  defp stopped(%Episode{state: :cancelled}, _turn) do
    %{
      action: "No action is required",
      attempted: [],
      headline: "Episode cancelled",
      href: nil,
      reason: "The durable episode owner recorded cancellation."
    }
  end

  defp stopped(_episode, %Turn{status: :blocked, delivery_ref: ref}) when is_binary(ref) do
    %{
      action:
        "Inspect the delivery failure and check the conversation before retrying the saved reply.",
      attempted: [],
      headline: "The reply could not be delivered",
      href: "/failures/delivery/#{segment(ref)}",
      reason: "The answer is already saved. Delivery recovery does not run the model again."
    }
  end

  defp stopped(episode, %Turn{status: :blocked} = turn) do
    recovery = WorkRecovery.brief(turn)

    attempts =
      [
        plural(turn.work_attempt_count || 0, "Work claim"),
        turn.candidate_attempt && plural(turn.candidate_attempt, "candidate attempt"),
        turn.coop_turn_id && "Coop turn created",
        turn.validation_intent && "host validation recorded"
      ]
      |> Enum.reject(&(&1 in [nil, "0 Work claims"]))

    %{
      action: recovery.next_step,
      attempted: attempts,
      headline: recovery.headline,
      model_output: recovery.model_output,
      delivery: recovery.delivery,
      not_started: recovery.not_started,
      href: recovery.setup_href || "/failures/work/#{segment(episode.key)}",
      link_label: if(recovery.setup_href, do: "View required setup", else: "Open recovery"),
      reason: recovery.cause
    }
  end

  defp stopped(_episode, _turn), do: nil

  @doc """
  Groups chronological entries by the conversation position each one actually
  belongs to.

  A step that carries a durable owner takes its position from that owner: a
  Turn sits at the position of the earliest input it selected, wherever its
  receipts happen to land in time. Only a step with no recorded owner falls
  back to the reader's current position, and an input message still opens a
  new one. This is what keeps a Turn 1 tool result that arrives after Message 2
  filed under Turn 1 instead of being blamed on a message that did not exist
  when the work started.
  """
  def chapters(steps, started_at, causality \\ EpisodeCausality.index([], [], [])) do
    {entries, _state} =
      Enum.map_reduce(steps, {0, MapSet.new()}, &conversation_part(&1, &2, causality))

    entries
    |> Enum.chunk_by(fn {step, part, _boundary, _owner} -> {step.band, part} end)
    |> Enum.map(fn chapter_entries ->
      [{_step, conversation_turn, _boundary, _owner} | _] = chapter_entries
      chapter_steps = Enum.map(chapter_entries, &elem(&1, 0))
      starts_conversation = Enum.any?(chapter_entries, &elem(&1, 2))
      owners = chapter_entries |> Enum.map(&elem(&1, 3)) |> Enum.uniq()

      {band, title, blurb} =
        Enum.find(@chapters, fn {band, _title, _blurb} ->
          band == List.first(chapter_steps).band
        end)

      %{
        band: band,
        title:
          if(starts_conversation and conversation_turn > 1, do: "Follow-up received", else: title),
        conversation_turn: conversation_turn,
        starts_conversation: starts_conversation,
        blurb: blurb,
        owners: owners,
        turn: chapter_turn(owners, causality),
        span: chapter_span(chapter_steps, started_at),
        steps: chapter_steps
      }
    end)
  end

  @doc "The single Work turn a chapter belongs to, or nil when it has none or several."
  def chapter_turn(owners, causality) do
    case Enum.filter(owners, &match?({:turn, _id}, &1)) do
      [owner] -> EpisodeCausality.describe(causality, owner)
      _none_or_several -> nil
    end
  end

  defp conversation_part(step, {part, seen}, causality) do
    owner = Map.get(step, :owner) || :episode
    boundary = message_boundary?(step, seen)

    part =
      cond do
        boundary -> part + 1
        position = EpisodeCausality.position(causality, owner) -> position
        true -> part
      end

    seen = if boundary, do: MapSet.put(seen, step.id), else: seen
    {{step, part, boundary, owner}, {part, seen}}
  end

  defp message_boundary?(%{kind: :message, band: :input, id: id}, seen),
    do: not MapSet.member?(seen, id)

  defp message_boundary?(_step, _seen), do: false

  defp chapter_span(steps, started_at) do
    values = steps |> Enum.map(&relative(&1.at, started_at)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      [one] -> one
      many -> List.first(many) <> " → " <> List.last(many)
    end
  end

  defp chronological(steps) do
    steps
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {time_key(item.at), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp step(id, band, at, attributes) do
    %{
      actor: human(Map.fetch!(attributes, :actor)),
      input_id: Map.get(attributes, :input_id),
      owner: Map.get(attributes, :owner, :episode),
      rules: Map.get(attributes, :rules),
      participation: Map.get(attributes, :participation),
      engagement: Map.get(attributes, :engagement),
      queue: Map.get(attributes, :queue),
      setup: Map.get(attributes, :setup),
      record_ref: Map.get(attributes, :record_ref),
      result_ref: Map.get(attributes, :result_ref),
      delivery_ref: Map.get(attributes, :delivery_ref),
      artifacts: Map.get(attributes, :artifacts, []),
      current_warning: Map.get(attributes, :current_warning),
      at: at,
      band: band,
      details: Map.fetch!(attributes, :details),
      duration_ms: Map.get(attributes, :duration_ms),
      tool_kind: Map.get(attributes, :tool_kind),
      path_context: Map.get(attributes, :path_context),
      href: Map.get(attributes, :href),
      id: id,
      stage: human(Map.fetch!(attributes, :stage)),
      # A step whose badge would only restate its own title carries no state at
      # all, rather than a word the reader has already read.
      state: attributes |> Map.get(:state) |> optional_human(),
      summary: present(Map.fetch!(attributes, :summary)),
      title: present(Map.fetch!(attributes, :title)),
      tone: Map.get(attributes, :tone)
    }
  end

  defp metric(label, value, detail, tone \\ nil),
    do: %{detail: to_string(detail), label: label, tone: tone, value: to_string(value)}

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

  # Creating an offer/question is model work. Only a delivery receipt proves it was sent.
  defp record_band(kind)
       when kind in [
              "input_request",
              "event_wait",
              "task_offer",
              "publication_offer",
              "schedule_offer",
              "automation_change_offer",
              "memory_offer",
              "preference_offer",
              "guidance_offer",
              "standing_assignment_offer",
              "slack_post_offer",
              "emisar_approval"
            ],
       do: :work

  defp record_band(_kind), do: :work

  defp record_stage("evidence"), do: "Evidence"
  defp record_stage("coverage"), do: "Coverage"
  defp record_stage("progress"), do: "Progress"
  defp record_stage("goal"), do: "Plan"
  defp record_stage("goal_state"), do: "Plan"
  defp record_stage("input_request"), do: "Wait"
  defp record_stage("event_wait"), do: "Wait"
  defp record_stage(_kind), do: "State record"

  defp record_title(%Record{kind: "progress"}, %{title: title}), do: "Progress · #{title}"
  defp record_title(%Record{kind: "input_request"}, _card), do: "Question prepared"
  defp record_title(%Record{kind: "event_wait"}, _card), do: "Wait prepared"
  defp record_title(%Record{kind: "goal"}, _card), do: "Goal recorded"

  defp record_title(%Record{kind: "evidence"}, %{title: title}),
    do: "Evidence recorded · #{title}"

  defp record_title(%Record{kind: "goal_state"}, %{title: title}), do: "Goal · #{title}"

  defp record_title(_record, %{label: label, title: title}) when is_binary(title),
    do: "#{label} · #{title}"

  defp record_title(record, _card), do: capitalize(human(record.kind)) <> " recorded"

  defp record_summary(%Record{kind: "input_request", payload: payload}, _card),
    do: payload["reason"] || "The model prepared a question for the reply."

  defp record_summary(_record, %{summary: summary}) when is_binary(summary), do: summary
  defp record_summary(%Record{subject_ref: value}, _card) when is_binary(value), do: value
  defp record_summary(%Record{operation_id: value}, _card), do: value

  defp record_details(record, nil),
    do: [{"Record", record.ref}, {"Operation", record.operation_id}]

  defp record_details(record, card) do
    [{"Record", record.ref}, {"Operation", record.operation_id}] ++
      Map.get(card, :details, [])
  end

  defp record_href(_record), do: nil

  defp coop_band(kind) when kind in ["turn", "candidate", "validation"], do: :work
  defp coop_band(_kind), do: :ready
  defp coop_title(kind), do: "Worker · #{human(kind)}"
  defp coop_summary(%{"state" => state}), do: "Worker reported #{human(state)}."
  defp coop_summary(_payload), do: "Bound worker event recorded."
  defp coop_tone(kind) when kind in ["candidate", "validation"], do: :good
  defp coop_tone(_kind), do: nil

  defp platform_action_title(:post_slack_message), do: "Additional message"
  defp platform_action_title(:set_slack_reaction), do: "Slack reaction"
  defp platform_action_title(:set_github_reaction), do: "GitHub reaction"
  defp platform_action_title(tool), do: human(tool)

  defp work_state(%Turn{remote_finished_at: nil}), do: "running"
  defp work_state(_turn), do: "finished"

  defp work_summary(%Turn{remote_finished_at: nil}),
    do: "The provider is still handling this turn."

  defp work_summary(_turn), do: "The provider finished and returned control to Ryker."

  defp validation_summary("reject", [], _turn),
    do: "Ryker rejected this candidate and requested a same-turn correction."

  defp validation_summary("reject", violations, _turn), do: Enum.join(violations, " ")

  defp validation_summary("accept", _violations, _turn),
    do: "The response passed the checks for this attempt."

  defp validation_summary(_verdict, _violations, _turn),
    do: "A candidate reached the host validation boundary."

  defp delivery_summary(%{"delivery" => "reply", "message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"message" => message}) when is_binary(message),
    do: "Ryker accepted this response for delivery."

  defp delivery_summary(%{"delivery" => "none", "decision_reason" => reason})
       when is_binary(reason),
       do: "No reply: " <> (reason |> redact_operator_text() |> bounded(240))

  defp delivery_summary(_document), do: "Accepted result recorded."

  defp delivery_confirmation(%{"message_ref" => "eval-message:" <> _}),
    do: "The private replay captured the response. Nothing was sent to Slack."

  defp delivery_confirmation(%{"transport" => "slack"}),
    do: "Slack transport confirmed the delivery."

  defp delivery_confirmation(%{"transport" => "control_plane"}),
    do: "The conversation recorded the response."

  defp delivery_confirmation(_), do: "The destination confirmed the delivery."

  defp delivery_actor(%{"transport" => transport}) when is_binary(transport), do: transport
  defp delivery_actor(_receipt), do: "Delivery"

  defp delivery_kind(%{"delivery" => value}), do: value
  defp delivery_kind(%{}), do: "reply"
  defp delivery_kind(_document), do: nil

  defp outcome_count(document, key) do
    case get_in(document || %{}, ["outcome", key]) do
      values when is_list(values) -> length(values)
      _other -> nil
    end
  end

  defp measurement_state(%Turn{timing_recorded: true, usage_recorded: true}),
    do: "usage and timing recorded"

  defp measurement_state(%Turn{timing_recorded: true}), do: "timing recorded; usage unmeasured"
  defp measurement_state(_turn), do: "unmeasured"

  defp candidate_parse(candidate) when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, value} when is_map(value) -> "JSON object"
      {:ok, _value} -> "JSON value; object required"
      {:error, _reason} -> "invalid JSON"
    end
  end

  defp candidate_parse(_candidate), do: "not recorded"

  defp parsed_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> time
      _invalid -> nil
    end
  end

  defp parsed_time(_value), do: nil

  defp source_text(%Entry{content: %{"text" => value}}) when is_binary(value),
    do: retained_text(value)

  defp source_text(%Entry{source_kind: "github", content: %{"payload" => payload}})
       when is_map(payload) do
    value =
      get_in(payload, ["comment", "body"]) || get_in(payload, ["review", "body"]) ||
        get_in(payload, ["issue", "body"]) || get_in(payload, ["pull_request", "body"])

    if is_binary(value), do: retained_text(value), else: nil
  end

  defp source_text(_input), do: nil

  defp source_attachments(%Entry{content: %{"files" => files}}) when is_list(files) do
    names =
      files
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [bounded(name, 128)]
        _file -> []
      end)
      |> Enum.take(5)

    [plural(length(files), "file"), Enum.join(names, " · ")]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp source_attachments(_input), do: nil

  defp source_link(episode, events, inputs) do
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

  defp review_state(%Episode{} = episode) do
    latest =
      Repo.one(
        from(review in EpisodeReview,
          where: review.episode_id == ^episode.id,
          order_by: [desc: review.semantic_version, desc: review.reviewed_at],
          limit: 1
        )
      )

    terminal = episode.state in [:complete, :cancelled]
    current = not is_nil(latest) and latest.semantic_version == episode.semantic_version

    %{
      actor_ref: latest && latest.actor_ref,
      at: latest && latest.reviewed_at,
      awaiting: terminal and not current,
      current: current,
      note: latest && latest.note,
      semantic_version: latest && latest.semantic_version
    }
  end

  defp operator_actions(episode, current_turn, review) do
    recovery =
      if current_blocked_turn?(episode, current_turn) and is_nil(current_turn.delivery_ref),
        do: WorkRecovery.brief(current_turn)

    []
    |> maybe_action(
      recovery != nil and recovery.action == :retry,
      if(recovery, do: recovery.action_label, else: "Retry work"),
      "/actions/work/#{segment(episode.key)}/retry",
      :primary
    )
    |> maybe_action(
      resolvable?(episode, current_turn),
      "Close as no longer needed",
      "/actions/episode/#{segment(episode.key)}/resolve",
      :danger
    )
    |> maybe_action(
      review.awaiting,
      "Mark ending reviewed",
      "/actions/episode/#{segment(episode.key)}/review",
      :secondary
    )
  end

  defp current_blocked_turn?(
         %Episode{state: :working, owner_kind: :turn, owner_ref: ref},
         %Turn{status: :blocked, turn_ref: ref}
       ),
       do: true

  defp current_blocked_turn?(_episode, _turn), do: false

  defp maybe_action(actions, true, label, href, tone),
    do: actions ++ [%{href: href, label: label, tone: tone}]

  defp maybe_action(actions, false, _label, _href, _tone), do: actions

  defp resolvable?(%Episode{state: state}, _turn)
       when state in [:waiting_for_input, :waiting_for_event],
       do: true

  defp resolvable?(%Episode{state: :working, owner_kind: :turn}, %Turn{status: :blocked}),
    do: true

  defp resolvable?(_episode, _turn), do: false

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

  defp retained_text(value) do
    "retained · #{byte_size(value)} bytes · sha256 #{value |> sha256() |> short_digest()} · content withheld"
  end

  defp redact_operator_text(value) do
    configured_secrets()
    |> Enum.reduce(value, &String.replace(&2, &1, "[redacted]"))
    |> String.replace(~r/(?i)\b(bearer\s+)[A-Za-z0-9._~+\/-]+/, "\\1[redacted]")
    |> String.replace(
      ~r/(?i)\b(password|passwd|token|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+/,
      "\\1=[redacted]"
    )
    |> String.replace(
      ~r/\b(?:xox[baprs]-|gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+/,
      "[redacted]"
    )
    |> scrub_embedded_urls()
  end

  defp scrub_embedded_urls(value) do
    Regex.replace(~r/https?:\/\/[^\s<>()]+/, value, fn url -> scrub_url(url) end)
  end

  defp configured_secrets do
    Application.get_all_env(:ryker)
    |> Enum.flat_map(fn {_key, value} -> secret_values(value, false) end)
    |> Enum.filter(&(byte_size(&1) >= 8))
    |> Enum.uniq()
  end

  defp secret_values(value, _inherited?) when is_struct(value), do: []

  defp secret_values(%{} = value, inherited?) do
    Enum.flat_map(value, fn {key, nested} ->
      secret? = inherited? or sensitive_key?(key) or key in [:secrets, "secrets"]
      secret_values(nested, secret?)
    end)
  end

  defp secret_values(value, inherited?) when is_list(value),
    do: Enum.flat_map(value, &secret_values(&1, inherited?))

  defp secret_values(value, true) when is_binary(value), do: [value]
  defp secret_values(_value, _inherited?), do: []

  defp sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp next_action(%Episode{state: :waiting_for_input}, _turn), do: "operator input"
  defp next_action(%Episode{state: :waiting_for_event}, _turn), do: "external event"
  defp next_action(_episode, %Turn{status: :blocked}), do: "operator recovery"
  defp next_action(%Episode{owner_kind: :delivery}, _turn), do: "deliver result"
  defp next_action(%Episode{state: :complete}, _turn), do: "complete"
  defp next_action(%Episode{state: :cancelled}, _turn), do: "cancelled"
  defp next_action(_episode, nil), do: "start work"
  defp next_action(_episode, _turn), do: "continue work"

  defp compact_details(values) do
    values
    |> Enum.flat_map(fn
      {_label, nil} -> []
      {_label, ""} -> []
      {label, %DateTime{} = value} -> [%{label: label, value: DateTime.to_iso8601(value)}]
      {label, value} -> [%{label: label, value: bounded(to_string(value), 1_024)}]
    end)
    |> Enum.take(20)
  end

  defp bounded_strings(values) when is_list(values) do
    values |> Enum.filter(&is_binary/1) |> Enum.map(&bounded(&1, 512)) |> Enum.take(16)
  end

  defp bounded_strings(_values), do: []

  defp bounded(value, maximum) when byte_size(value) <= maximum, do: value
  defp bounded(value, maximum), do: String.slice(value, 0, maximum) <> "…"

  defp short_digest(value) when is_binary(value) and byte_size(value) > 12,
    do: binary_part(value, 0, 12) <> "…"

  defp short_digest(value) when is_binary(value), do: value
  defp short_digest(_value), do: nil

  defp join_ref(nil, nil), do: nil

  defp join_ref(kind, ref),
    do: [kind, ref] |> Enum.reject(&is_nil/1) |> Enum.map_join(":", &to_string/1)

  defp elapsed(%DateTime{} = left, %DateTime{} = right),
    do: format_ms(max(DateTime.diff(right, left, :millisecond), 0))

  defp elapsed(_left, _right), do: "unmeasured"

  defp relative(%DateTime{} = at, %DateTime{} = started_at),
    do: "+" <> format_ms(max(DateTime.diff(at, started_at, :millisecond), 0))

  defp relative(_at, _started_at), do: nil

  defp time_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp time_key(_value), do: 9_223_372_036_854_775_807

  defp format_ms(nil), do: nil
  defp format_ms(value) when value < 1_000, do: "#{value} ms"
  defp format_ms(value) when value < 60_000, do: format_decimal(value / 1_000, "s")
  defp format_ms(value) when value < 3_600_000, do: format_decimal(value / 60_000, "m")
  defp format_ms(value), do: format_decimal(value / 3_600_000, "h")

  defp format_decimal(value, suffix) do
    number =
      :erlang.float_to_binary(value, decimals: 1)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    number <> suffix
  end

  defp format_integer(value),
    do:
      Integer.to_string(value)
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(value, noun), do: "#{value} #{noun}s"
  defp plural(1, noun, _plural), do: "1 #{noun}"
  defp plural(value, _noun, plural), do: "#{value} #{plural}"

  defp optional_human(nil), do: nil
  defp optional_human(value), do: human(value)

  defp human(nil), do: "unrecorded"
  defp human(value) when is_atom(value), do: value |> Atom.to_string() |> human()
  defp human(value) when is_binary(value), do: String.replace(value, "_", " ")
  # Retained payloads carry whatever an older worker wrote. A structured value
  # where a label was expected is unreadable, not a reason to lose the page.
  defp human(value) when is_map(value) or is_list(value), do: "unreadable"
  defp human(value), do: to_string(value)

  defp capitalize(value), do: String.capitalize(value)

  defp present(nil), do: nil
  defp present(value), do: bounded(to_string(value), 2_000)

  defp state_tone(state)
       when state in [:blocked, "blocked", :failed, "failed", :superseded, "superseded"], do: :bad

  defp state_tone(state)
       when state in [
              :complete,
              "complete",
              :settled,
              "settled",
              :delivered,
              "delivered",
              :published,
              "published",
              :ready,
              "ready",
              :active,
              "active"
            ],
       do: :good

  defp state_tone(state)
       when state in [
              :waiting_for_input,
              :waiting_for_event,
              :cancelled,
              :cancel_pending,
              :pending,
              :review_pending,
              :publish_pending
            ],
       do: :warn

  defp state_tone(_state), do: nil

  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)
end
