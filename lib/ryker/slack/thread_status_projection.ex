defmodule Ryker.Slack.ThreadStatusProjection do
  @moduledoc """
  Projects durable ingress, episode ownership and the running turn's narrated
  activity onto Slack assistant threads.

  The database remains authoritative. Recent terminal rows are included so a
  restarted worker can clear a status that Slack still displays.

  While a turn runs, the line names what it is doing from the latest tool the
  worker narrated for that turn. Each kind of tool has one fixed phrase: the
  channel sees no tool argument, command, path, title or model text.
  """

  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.ThreadStatuses
  alias Ryker.Work.{ActivityEvent, Turn}

  @recent_terminal_seconds 24 * 60 * 60
  @maximum_rows 1_000

  @getting_started "is getting started…"
  @thinking "is thinking…"
  @working "is working…"

  # Ryker's own tools, which the worker names under this server. Only a live
  # turn shows a status, and none has used the pre-rename name since 2026-09-26.
  @state_server "controller-tools"
  @state_tool_phrases [
    {"is searching what it knows…", ~w(search_memory)},
    {"is searching Slack…", ~w(search_slack list_slack_channels)},
    {"is reading Slack messages…", ~w(read_slack_source)},
    {"is reacting to a message…", ~w(set_slack_reaction set_github_reaction)},
    {"is drafting a Slack message…", ~w(post_slack_message)},
    {"is posting an update…", ~w(post_slack_update)},
    {"is reading GitHub…", ~w(read_github_conversation)},
    {"is reading a pull request…", ~w(read_github_pull_request)},
    {"is searching GitHub…", ~w(search_github)},
    {"is checking CI…", ~w(read_github_ci)},
    {"is rerunning CI…", ~w(rerun_github_ci)},
    {"is stopping a CI run…", ~w(cancel_github_ci)},
    {"is submitting a review…", ~w(submit_github_review)},
    {"is noting what it found…", ~w(cite_source record_finding)},
    {"is planning next steps…", ~w(plan_goal update_goal get_work_state)},
    {"is preparing a question…", ~w(request_input)},
    {"is setting up a follow-up…", ~w(wait_for)},
    {"is checking automations…", ~w(list_automations get_automation)},
    {"is setting up an automation…", ~w(propose_automation)},
    {"is preparing a task…", ~w(request_task)},
    {"is noting something to remember…", ~w(propose_memory remember_answer)},
    {"is noting a preference…", ~w(propose_preference)},
    {"is noting feedback…", ~w(record_feedback)},
    {"is asking for approval…", ~w(record_emisar_approval)},
    {"is writing the reply…", ~w(update_conversation_summary validate_final)}
  ]

  # Emisar's tools, by the server name its connection gives the worker, or
  # through Ryker's own server, which has offered them since 2026-09-27. The
  # action a run asks for is the model's argument and stays out of the line.
  @emisar_server "emisar"
  @emisar_tool_phrases [
    {"is asking Emisar to run an action…", ~w(run_action)},
    {"is asking Emisar to run a runbook…", ~w(execute_runbook)},
    {"is asking Emisar to stop a run…", ~w(cancel_run)},
    {"is waiting for Emisar…", ~w(wait_for_run get_operation)},
    {"is checking recent Emisar runs…", ~w(recent_runs)},
    {"is looking up Emisar actions…",
     ~w(find_actions get_action list_packs list_runners list_runbooks get_runbook)},
    {"is drafting a runbook…", ~w(create_runbook_draft update_runbook_draft)}
  ]

  # The worker's built-in tools, by the kind it reports for each call.
  @tool_kind_phrases [
    {"is reading the code…", ~w(read)},
    {"is searching the code…", ~w(search)},
    {"is editing the code…", ~w(edit delete move)},
    {"is running a command…", ~w(execute)},
    {"is reading a web page…", ~w(fetch)},
    {@thinking, ~w(think)}
  ]

  @narration_kinds ~w(tool.started model.progress model.thought model.plan)
  @heard_kinds @narration_kinds ++ ~w(tool.completed provider.alive)

  # A step names what the turn is doing only while the turn still narrates.
  # Healthy runs pause for seconds between steps; a turn that stalled for two
  # hours after checking its reply would otherwise have said "is writing the
  # reply…" the whole time.
  @quiet_after_seconds 5 * 60

  @spec snapshot(String.t()) :: {:ok, [map()]} | {:error, term()}
  def snapshot(workspace_ref) when is_binary(workspace_ref) and workspace_ref != "" do
    cutoff = DateTime.add(DateTime.utc_now(), -@recent_terminal_seconds, :second)
    episodes = recent_episodes(workspace_ref, cutoff)

    {:ok,
     targets(
       recent_entries(workspace_ref, cutoff),
       episodes,
       owning_turns(episodes),
       workspace_ref
     )}
  rescue
    error -> {:error, {:slack_thread_status_projection_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:slack_thread_status_projection_failed, kind, inspect(reason)}}
  end

  def snapshot(_workspace_ref), do: {:error, {:invalid_slack_thread_status, :workspace_ref}}

  defp recent_entries(workspace_ref, cutoff) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.source_kind == "slack" and entry.source_ref == ^workspace_ref and
            entry.destination_transport == "slack" and entry.execution_mode == :live and
            (entry.status in [:pending, :blocked] or entry.updated_at >= ^cutoff),
        order_by: [desc: entry.updated_at],
        limit: @maximum_rows
      )
    )
  end

  defp recent_episodes(workspace_ref, cutoff) do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and episode.execution_mode == :live and
            fragment(
              "split_part(?, ':', 1) = 'slack' AND split_part(?, ':', 2) = ?",
              episode.destination_conversation_ref,
              episode.destination_conversation_ref,
              ^workspace_ref
            ) and
            (episode.state in [:working, :waiting_for_input, :waiting_for_event] or
               episode.updated_at >= ^cutoff),
        order_by: [desc: episode.updated_at],
        limit: @maximum_rows
      )
    )
  end

  # What each working episode's owning turn is doing, keyed by episode and turn
  # ref: `:parked`, or `{:working, phrase}`.
  #
  # Blocking a turn does not transition its episode, so a parked task is still a
  # `:working` row owned by a turn that stopped. Without this the thread keeps
  # refreshing "is working…" every 90 seconds for work nobody is doing.
  defp owning_turns(episodes) do
    owners =
      for %Episode{id: id, state: :working, owner_kind: :turn, owner_ref: ref} <- episodes,
          is_binary(ref),
          into: MapSet.new(),
          do: {id, ref}

    if MapSet.size(owners) == 0 do
      %{}
    else
      {episode_ids, turn_refs} = owners |> MapSet.to_list() |> Enum.unzip()

      turns =
        from(turn in Turn,
          where: turn.episode_id in ^episode_ids and turn.turn_ref in ^turn_refs,
          select: %{
            coop_turn_id: turn.coop_turn_id,
            episode_id: turn.episode_id,
            session_id: turn.session_id,
            status: turn.status,
            turn_ref: turn.turn_ref
          }
        )
        |> Repo.all()
        |> Enum.filter(&MapSet.member?(owners, {&1.episode_id, &1.turn_ref}))

      narration = latest_narration(turns)
      Map.new(turns, &{{&1.episode_id, &1.turn_ref}, turn_progress(&1, narration)})
    end
  end

  # One entry per running remote turn: its latest tool start, or, before its
  # first tool, its latest model narration, or `:quiet` once it has narrated
  # nothing for five minutes. A finished tool keeps its phrase until the next
  # one starts, so the line does not flicker between calls. The remote turn
  # id is the turn's own: a follow-up in the same session never inherits the
  # last step of the answer before it.
  defp latest_narration(turns) do
    case for(%{status: :pending, coop_turn_id: id} <- turns, is_binary(id), do: id) do
      [] ->
        %{}

      remote_turns ->
        quiet_since = DateTime.add(DateTime.utc_now(), -@quiet_after_seconds, :second)
        heard = last_heard(remote_turns)
        Map.new(latest_steps(remote_turns), &unless_quiet(&1, heard, quiet_since))
    end
  end

  # A step recorded after `last_heard` read is as fresh as it gets.
  defp unless_quiet({key, step}, heard, quiet_since) do
    if DateTime.compare(Map.get(heard, key, quiet_since), quiet_since) == :lt,
      do: {key, :quiet},
      else: {key, step}
  end

  defp latest_steps(remote_turns) do
    from(event in ActivityEvent,
      where: event.coop_turn_id in ^remote_turns and event.kind in ^@narration_kinds,
      distinct: [event.session_id, event.coop_turn_id],
      order_by: [desc: fragment("? = 'tool.started'", event.kind), desc: event.sequence],
      select: {{event.session_id, event.coop_turn_id}, {event.kind, event.payload}}
    )
    |> Repo.all()
  end

  defp last_heard(remote_turns) do
    from(event in ActivityEvent,
      where: event.coop_turn_id in ^remote_turns and event.kind in ^@heard_kinds,
      group_by: [event.session_id, event.coop_turn_id],
      select: {{event.session_id, event.coop_turn_id}, max(event.occurred_at)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp turn_progress(%{status: :blocked}, _narration), do: :parked

  defp turn_progress(%{status: :pending} = turn, narration),
    do: {:working, narration |> Map.get({turn.session_id, turn.coop_turn_id}) |> phrase()}

  # A turn being stopped is no longer doing its last tool.
  defp turn_progress(_turn, _narration), do: {:working, @working}

  defp phrase(nil), do: @getting_started
  defp phrase(:quiet), do: @working
  defp phrase({"tool.started", payload}), do: tool_phrase(payload)
  defp phrase({_model_narration, _payload}), do: @thinking

  # Only the server, the tool name and the kind are read, and only to choose
  # a phrase; a name no table knows says "is working…".
  defp tool_phrase(%{"input" => %{"server" => server, "tool" => tool}})
       when server == @state_server,
       do: phrase_for(@state_tool_phrases ++ @emisar_tool_phrases, tool)

  defp tool_phrase(%{"input" => %{"server" => @emisar_server, "tool" => tool}}),
    do: phrase_for(@emisar_tool_phrases, tool)

  # Any other MCP server's tool, and an input too large to keep whole, whose
  # server is unknown: the worker reports both as `execute`, which would read
  # as a command.
  defp tool_phrase(%{"input" => %{"server" => _server}}), do: @working
  defp tool_phrase(%{"input" => %{"truncated" => true}}), do: @working
  defp tool_phrase(%{"kind" => kind}), do: phrase_for(@tool_kind_phrases, kind)
  defp tool_phrase(_payload), do: @working

  defp phrase_for(table, name),
    do: Enum.find_value(table, @working, fn {phrase, names} -> if name in names, do: phrase end)

  # One status per thread, at most as many as one reconcile takes. Past that
  # bound the live ones are kept: a finished thread left out is cleared anyway,
  # while refusing the whole list stopped every status in the workspace.
  @doc false
  @spec targets([Entry.t()], [Episode.t()], map(), String.t()) :: [map()]
  def targets(entries, episodes, turns, workspace_ref)
      when is_list(entries) and is_list(episodes) and is_map(turns) and
             is_binary(workspace_ref) do
    (Enum.flat_map(entries, &entry_candidate(&1, workspace_ref)) ++
       Enum.flat_map(episodes, &episode_candidate(&1, turns, workspace_ref)))
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, candidates} -> Enum.max_by(candidates, & &1.priority) end)
    |> Enum.sort_by(& &1.priority, :desc)
    |> Enum.take(ThreadStatuses.maximum_targets())
    |> Enum.map(&Map.drop(&1, [:key, :priority]))
    |> Enum.sort_by(&{&1.channel_ref, &1.thread_ref})
  end

  defp entry_candidate(%Entry{execution_mode: :live} = entry, workspace_ref) do
    with {:ok, key} <- destination(entry, workspace_ref),
         {:ok, phase, status, priority} <- entry_status(entry) do
      [
        Map.merge(candidate(key, phase, status, priority), %{
          origin_kind: "input",
          origin_id: entry.id
        })
      ]
    else
      _invalid -> []
    end
  end

  defp entry_candidate(_entry, _workspace_ref), do: []

  defp episode_candidate(%Episode{execution_mode: :live} = episode, turns, workspace_ref) do
    with {:ok, key} <- destination(episode, workspace_ref),
         {:ok, phase, status, priority} <- episode_status(episode, turns) do
      [
        Map.merge(candidate(key, phase, status, priority), %{
          origin_kind: "episode",
          origin_id: episode.id
        })
      ]
    else
      _invalid -> []
    end
  end

  defp episode_candidate(_episode, _turns, _workspace_ref), do: []

  defp entry_status(%Entry{status: :blocked}),
    do: {:ok, :blocked, "", 110}

  defp entry_status(%Entry{status: :pending, lease_ref: lease_ref})
       when is_binary(lease_ref) and lease_ref != "",
       do: {:ok, :admitting, "is deciding how to respond…", 100}

  defp entry_status(%Entry{status: :pending, next_attempt_at: %DateTime{}}),
    do: {:ok, :admission_retry, "is waiting to try again…", 90}

  defp entry_status(%Entry{status: :pending}), do: {:ok, :queued, "is queued…", 80}

  defp entry_status(%Entry{status: status}) when status in [:decided, :superseded],
    do: {:ok, :clear, "", 10}

  defp entry_status(_entry), do: :ignore

  defp episode_status(%Episode{state: :working, owner_kind: :delivery}, _turns),
    do: {:ok, :delivery, "is posting the reply…", 75}

  # Below every entry phase, so a new message on the same thread still reports
  # itself rather than being silenced by the parked task it arrived beside.
  # Until Work creates the turn, the worker session is still starting.
  defp episode_status(%Episode{state: :working, owner_kind: :turn} = episode, turns) do
    case Map.get(turns, {episode.id, episode.owner_ref}, {:working, @getting_started}) do
      :parked -> {:ok, :blocked, "", 65}
      {:working, phrase} -> {:ok, :working, phrase, 70}
    end
  end

  defp episode_status(%Episode{state: :working}, _turns),
    do: {:ok, :working, @working, 70}

  defp episode_status(%Episode{state: :waiting_for_input}, _turns),
    do: {:ok, :waiting_for_input, "", 60}

  defp episode_status(%Episode{state: :waiting_for_event}, _turns),
    do: {:ok, :waiting_for_event, "", 60}

  defp episode_status(%Episode{state: state}, _turns) when state in [:complete, :cancelled],
    do: {:ok, :clear, "", 20}

  defp episode_status(_episode, _turns), do: :ignore

  defp destination(
         %{
           destination_conversation_ref: conversation_ref,
           destination_thread_ref: thread_ref,
           destination_transport: "slack"
         },
         workspace_ref
       ) do
    case String.split(conversation_ref || "", ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref]
      when byte_size(channel_ref) > 0 and is_binary(thread_ref) and byte_size(thread_ref) > 0 ->
        if Regex.match?(~r/\A[A-Z0-9]+\z/, channel_ref) and
             Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, thread_ref) do
          {:ok, {channel_ref, thread_ref}}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp destination(_record, _workspace_ref), do: :error

  defp candidate({channel_ref, thread_ref} = key, phase, status, priority) do
    %{
      channel_ref: channel_ref,
      key: key,
      phase: phase,
      priority: priority,
      status: status,
      thread_ref: thread_ref
    }
  end
end
