defmodule Ryker.Acceptance.Live do
  @moduledoc """
  Runs the replacement product's opt-in Slack acceptance against one active deployment.

  The harness posts a real root message in an explicitly joined test channel, then
  records uniquely identified synthetic operator inputs through the production Slack
  gateway. The already-running deployment owns Admission, Work, remote Coop execution,
  state tools, and Delivery. This process only observes their durable PostgreSQL custody.
  """

  import Ecto.Query

  alias Ryker.{Bootstrap, Settings}
  alias Ryker.CoopFleet.Placement
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Runtime.Assembly
  alias Ryker.Slack.{Client, Gateway, Runtime}
  alias Ryker.Work.Turn

  @default_timeout_ms 10 * 60 * 1_000
  @poll_interval_ms 500
  @maximum_timeout_ms 30 * 60 * 1_000
  @operation_fields [
    :admit,
    :conversation_info,
    :monotonic_ms,
    :now,
    :observe,
    :post_message,
    :ready,
    :sleep
  ]

  @type report :: %{
          episode_id: String.t(),
          release_version: String.t(),
          root_message_ref: String.t(),
          run_id: String.t(),
          session_id: String.t(),
          synthetic_inputs: true,
          turn_ids: [String.t()],
          worker_placement: map() | nil
        }

  @spec run(map(), String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(configuration, channel_ref, options \\ []) do
    with {:ok, settings} <- settings(configuration, channel_ref, options),
         :ok <- settings.operations.ready.(),
         {:ok, channel} <- settings.operations.conversation_info.(channel_ref),
         :ok <- safe_channel(channel, channel_ref),
         {:ok, root_message_ref} <- post_root(settings),
         {:ok, first} <- execute_input(settings, root_message_ref, :first, []),
         {:ok, followup} <-
           execute_input(settings, root_message_ref, :followup, [first.turn_id]),
         :ok <- same_continuation(first, followup),
         :ok <- same_execution_boundary(settings, first, followup),
         :ok <- exact_delivery(first, settings, root_message_ref),
         :ok <- exact_delivery(followup, settings, root_message_ref) do
      {:ok,
       %{
         episode_id: first.episode_id,
         release_version: release_version(),
         root_message_ref: root_message_ref,
         run_id: settings.run_id,
         session_id: first.session_id,
         synthetic_inputs: true,
         turn_ids: [first.turn_id, followup.turn_id],
         worker_placement: first.worker_placement
       }}
    end
  rescue
    error -> {:error, {:live_acceptance_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:live_acceptance_caught, kind, inspect(reason)}}
  end

  @spec run_from_env!() :: :ok
  def run_from_env! do
    channel_ref = System.get_env("RYKER_LIVE_CHANNEL")
    timeout_seconds = System.get_env("RYKER_LIVE_TIMEOUT_SECONDS", "600")

    with :ok <- reference(channel_ref, :channel_ref),
         {timeout_seconds, ""} <- Integer.parse(timeout_seconds),
         true <- timeout_seconds in 1..div(@maximum_timeout_ms, 1_000),
         {:ok, report} <-
           with_repo_and_finch(:durable_settings, channel_ref, timeout_seconds * 1_000) do
      IO.puts(Jason.encode!(string_keys(report)))
      :ok
    else
      false -> raise "live acceptance timeout is invalid"
      :error -> raise "live acceptance timeout is invalid"
      {:error, reason} -> raise "live acceptance failed: #{inspect(reason)}"
      {_value, _remainder} -> raise "live acceptance timeout is invalid"
    end
  end

  defp with_repo_and_finch(configuration, channel_ref, timeout_ms) do
    case Ecto.Migrator.with_repo(
           Repo,
           &run_with_finch(&1, configuration, channel_ref, timeout_ms),
           mode: :temporary,
           pool_size: 2
         ) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> {:error, {:live_acceptance_repository_unavailable, reason}}
    end
  end

  defp run_with_finch(_repo, :durable_settings, channel_ref, timeout_ms) do
    # The harness observes the deployment that is already running, so it reads
    # the same durable settings that deployment applied.
    with {:ok, settings} <- Settings.fetch(),
         {:ok, configuration} <- Assembly.build(Bootstrap.load!(), settings) do
      with_finch(fn -> run(configuration, channel_ref, timeout_ms: timeout_ms) end)
    end
  end

  defp with_finch(function) do
    case Finch.start_link(name: Ryker.CoopFinch) do
      {:ok, pid} ->
        try do
          function.()
        after
          GenServer.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        function.()

      {:error, reason} ->
        {:error, {:live_acceptance_http_unavailable, reason}}
    end
  end

  defp settings(configuration, channel_ref, options) do
    with :ok <- reference(channel_ref, :channel_ref),
         {:ok, options} <- options(options),
         {:ok, slack} <- slack(configuration),
         {:ok, operator_ref} <- first_operator(slack.operators),
         {:ok, operations} <- operations(configuration, slack, options[:operations]),
         run_id <- options[:run_id] || generated_run_id(),
         :ok <- reference(run_id, :run_id),
         timeout_ms <- options[:timeout_ms] || @default_timeout_ms,
         true <- is_integer(timeout_ms) and timeout_ms in 1..@maximum_timeout_ms,
         {:ok, execution_mode} <- execution_mode(configuration) do
      {:ok,
       %{
         bot_user_ref: slack.identity.bot_user_ref,
         channel_ref: channel_ref,
         execution_mode: execution_mode,
         operations: operations,
         operator_ref: operator_ref,
         repository_ref: slack.default_repository,
         run_id: run_id,
         timeout_ms: timeout_ms,
         workspace_ref: slack.identity.workspace_ref
       }}
    else
      false -> {:error, {:invalid_live_acceptance, :timeout_ms}}
      {:error, _reason} = error -> error
    end
  end

  defp options(options) when is_list(options) do
    allowed = [:operations, :run_id, :timeout_ms]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [],
       do: {:ok, options},
       else: {:error, {:invalid_live_acceptance, :options}}
  end

  defp options(_options), do: {:error, {:invalid_live_acceptance, :options}}

  defp slack(%{
         slack:
           %{default_repository: repository, identity: identity, operators: operators} = slack
       })
       when is_binary(repository) and is_map(identity) and is_list(operators) do
    with :ok <- reference(repository, :repository_ref),
         :ok <- identity(identity) do
      {:ok, slack}
    end
  end

  defp slack(_configuration), do: {:error, :live_acceptance_slack_not_configured}

  defp identity(%{bot_user_ref: bot_user_ref, workspace_ref: workspace_ref}) do
    with :ok <- reference(bot_user_ref, :bot_user_ref),
         do: reference(workspace_ref, :workspace_ref)
  end

  defp identity(_identity), do: {:error, {:invalid_live_acceptance, :identity}}

  defp first_operator([operator_ref | _rest]) do
    case reference(operator_ref, :operator_ref) do
      :ok -> {:ok, operator_ref}
      {:error, _reason} = error -> error
    end
  end

  defp first_operator(_operators), do: {:error, :live_acceptance_operator_not_configured}

  defp operations(_configuration, _slack, %{} = operations) do
    if Map.keys(operations) |> Enum.sort() == Enum.sort(@operation_fields) and
         Enum.all?(@operation_fields, &is_function(operations[&1], operation_arity(&1))) do
      {:ok, operations}
    else
      {:error, {:invalid_live_acceptance, :operations}}
    end
  end

  defp operations(configuration, slack, nil) do
    gateway = Runtime.options!(slack).handler_settings
    client = gateway.client

    operations(configuration, slack, %{
      admit: fn envelope -> production_admit(envelope, gateway) end,
      conversation_info: &Client.conversation_info(client, &1),
      monotonic_ms: fn -> System.monotonic_time(:millisecond) end,
      now: &DateTime.utc_now/0,
      observe: &observe/2,
      post_message: &Client.post_message(client, &1, &2, &3, &4),
      ready: fn -> deployment_ready(configuration) end,
      sleep: &Process.sleep/1
    })
  rescue
    error -> {:error, {:invalid_live_acceptance, Exception.message(error)}}
  end

  defp operations(_configuration, _slack, _operations),
    do: {:error, {:invalid_live_acceptance, :operations}}

  defp operation_arity(name) when name in [:monotonic_ms, :now, :ready], do: 0
  defp operation_arity(name) when name in [:admit, :conversation_info, :sleep], do: 1
  defp operation_arity(:observe), do: 2
  defp operation_arity(:post_message), do: 4

  defp safe_channel(
         %{
           "id" => channel_ref,
           "is_archived" => false,
           "is_member" => true,
           "name" => name
         } = channel,
         channel_ref
       )
       when is_binary(name) do
    test_name = name == "test" or String.ends_with?(name, "-test")

    if test_name and Map.get(channel, "is_ext_shared", false) == false,
      do: :ok,
      else: {:error, :live_acceptance_channel_not_safe}
  end

  defp safe_channel(_channel, _channel_ref),
    do: {:error, :live_acceptance_channel_not_safe}

  defp post_root(settings) do
    document = %{
      "message" =>
        "Automated Ryker product acceptance #{settings.run_id}. " <>
          "This thread uses synthetic operator inputs and real Admission, Work, Coop, and Delivery custody."
    }

    settings.operations.post_message.(
      settings.channel_ref,
      nil,
      document,
      "live-acceptance:#{settings.run_id}:root"
    )
  end

  defp execute_input(settings, root_message_ref, kind, previous_turn_ids) do
    event_ref = "#{settings.run_id}:#{kind}"
    prompt = prompt(kind, settings.repository_ref)
    sequence = if(kind == :first, do: 1, else: 2)

    with {:ok, occurred_at} <- utc_now(settings.operations.now),
         do:
           admit_and_wait(
             settings,
             envelope(settings, root_message_ref, event_ref, prompt, occurred_at, sequence),
             event_ref,
             previous_turn_ids
           )
  end

  defp admit_and_wait(settings, envelope, event_ref, previous_turn_ids) do
    with {:ok, _input_ref} <- settings.operations.admit.(envelope),
         do: wait_for_result(settings, event_ref, previous_turn_ids)
  end

  defp prompt(:first, repository_ref) do
    "Reply in one concise sentence. State that this live acceptance run is active, " <>
      "identify the configured repository #{repository_ref}, and create no incident, task, " <>
      "memory, schedule, publication, or governed action."
  end

  defp prompt(:followup, _repository_ref) do
    "In one concise sentence, name the repository you identified in your previous reply. " <>
      "Use the same conversation and create no new state."
  end

  defp envelope(settings, root_message_ref, event_ref, prompt, occurred_at, sequence) do
    message_ref = slack_timestamp(occurred_at, sequence)

    %{
      "envelope_id" => "live-envelope:#{event_ref}",
      "payload" => %{
        "event" => %{
          "channel" => settings.channel_ref,
          "event_ts" => message_ref,
          "text" => "<@#{settings.bot_user_ref}> #{prompt}",
          "thread_ts" => root_message_ref,
          "ts" => message_ref,
          "type" => "app_mention",
          "user" => settings.operator_ref
        },
        "event_id" => event_ref,
        "team_id" => settings.workspace_ref,
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  defp production_admit(envelope, gateway) do
    case Gateway.handle_envelope(envelope, gateway) do
      {:ack, {:recorded, input_ref}} -> {:ok, input_ref}
      {:ack, {:duplicate, input_ref}} -> {:ok, input_ref}
      {:ack, outcome} -> {:error, {:live_acceptance_input_not_recorded, outcome}}
      {:retry, reason} -> {:error, {:live_acceptance_input_retry, reason}}
      :ignore -> {:error, :live_acceptance_input_ignored}
      other -> {:error, {:live_acceptance_input_invalid, other}}
    end
  end

  @doc false
  @spec deployment_ready(map()) :: :ok | {:error, term()}
  def deployment_ready(%{control_plane: %{ip: ip, port: port}})
      when is_tuple(ip) and is_integer(port) do
    host = ip |> :inet.ntoa() |> to_string()
    authority = if String.contains?(host, ":"), do: "[#{host}]", else: host
    request = Finch.build(:get, "http://#{authority}:#{port}/readyz")
    expected_version = release_version()

    case Finch.request(request, Ryker.CoopFinch, receive_timeout: 5_000) do
      {:ok, %Finch.Response{headers: headers, status: 200}} ->
        case List.keyfind(headers, "x-ryker-version", 0) do
          {"x-ryker-version", ^expected_version} -> :ok
          _missing_or_crossed -> {:error, :live_acceptance_release_version_mismatch}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:live_acceptance_deployment_not_ready, status}}

      {:error, reason} ->
        {:error, {:live_acceptance_deployment_unreachable, reason}}
    end
  end

  def deployment_ready(_configuration),
    do: {:error, :live_acceptance_control_plane_not_configured}

  defp wait_for_result(settings, event_ref, previous_turn_ids) do
    deadline = settings.operations.monotonic_ms.() + settings.timeout_ms
    wait_for_result(settings, event_ref, previous_turn_ids, deadline)
  end

  defp wait_for_result(settings, event_ref, previous_turn_ids, deadline) do
    case settings.operations.observe.(event_ref, previous_turn_ids) do
      {:ok, snapshot} ->
        validate_snapshot(snapshot)

      :pending ->
        if settings.operations.monotonic_ms.() < deadline do
          settings.operations.sleep.(@poll_interval_ms)
          wait_for_result(settings, event_ref, previous_turn_ids, deadline)
        else
          {:error, {:live_acceptance_timeout, event_ref}}
        end

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:live_acceptance_observation_invalid, other}}
    end
  end

  @doc false
  @spec observe(String.t(), [Ecto.UUID.t()]) :: :pending | {:ok, map()} | {:error, term()}
  def observe(event_ref, previous_turn_ids) do
    entry =
      Repo.one(
        from(value in Entry,
          where: value.source_kind == "slack" and value.event_ref == ^event_ref,
          order_by: [desc: value.inserted_at],
          limit: 1
        )
      )

    observe_entry(entry, previous_turn_ids)
  end

  defp observe_entry(nil, _previous_turn_ids), do: :pending
  defp observe_entry(%Entry{status: :pending}, _previous_turn_ids), do: :pending

  defp observe_entry(%Entry{status: :blocked} = entry, _previous_turn_ids),
    do: {:error, {:live_acceptance_admission_blocked, entry.last_error_code}}

  defp observe_entry(%Entry{status: :superseded}, _previous_turn_ids),
    do: {:error, :live_acceptance_input_superseded}

  defp observe_entry(%Entry{status: :decided, episode_id: nil}, _previous_turn_ids),
    do: {:error, :live_acceptance_input_created_no_episode}

  defp observe_entry(%Entry{status: :decided, episode_id: episode_id}, previous_turn_ids) do
    turn =
      Repo.one(
        from(value in Turn,
          where: value.episode_id == ^episode_id and value.id not in ^previous_turn_ids,
          order_by: [desc: value.inserted_at, desc: value.id],
          limit: 1
        )
      )

    observe_turn(turn, episode_id)
  end

  defp observe_turn(nil, _episode_id), do: :pending

  defp observe_turn(%Turn{status: status} = turn, _episode_id)
       when status in [:blocked, :cancel_pending, :superseded],
       do: {:error, {:live_acceptance_work_failed, status, turn.last_error_code}}

  defp observe_turn(%Turn{status: :settled} = turn, episode_id) do
    {:ok,
     %{
       delivery_document: turn.delivery_document,
       episode_id: episode_id,
       external_receipt: turn.external_receipt,
       session_id: turn.session_id,
       turn_id: turn.id,
       worker_placement: worker_placement(turn.session_id)
     }}
  end

  defp observe_turn(%Turn{}, _episode_id), do: :pending

  defp validate_snapshot(
         %{
           delivery_document: %{"message" => message},
           episode_id: episode_id,
           external_receipt: %{} = receipt,
           session_id: session_id,
           turn_id: turn_id,
           worker_placement: placement
         } = snapshot
       )
       when is_binary(message) and is_binary(episode_id) and is_binary(session_id) and
              is_binary(turn_id) do
    cond do
      not valid_worker_placement?(placement) ->
        {:error, :live_acceptance_snapshot_invalid}

      String.trim(message) == "" or map_size(receipt) != 5 ->
        {:error, :live_acceptance_empty_delivery}

      true ->
        {:ok, snapshot}
    end
  end

  defp validate_snapshot(_snapshot), do: {:error, :live_acceptance_snapshot_invalid}

  defp same_continuation(first, followup) do
    cond do
      first.episode_id != followup.episode_id ->
        {:error, :live_acceptance_followup_changed_episode}

      first.turn_id == followup.turn_id ->
        {:error, :live_acceptance_followup_reused_turn}

      true ->
        :ok
    end
  end

  # A fleet build runs every turn on an enrolled worker, so a settled turn
  # without a placement means the harness watched something other than the
  # product topology. An isolated build has no placement to prove.
  defp same_execution_boundary(%{execution_mode: :fleet}, first, followup) do
    if is_nil(first.worker_placement) or is_nil(followup.worker_placement),
      do: {:error, :live_acceptance_remote_placement_missing},
      else: :ok
  end

  defp same_execution_boundary(%{execution_mode: :direct}, _first, _followup), do: :ok

  defp execution_mode(%{execution_mode: mode}) when mode in [:direct, :fleet], do: {:ok, mode}
  defp execution_mode(_configuration), do: {:error, {:invalid_live_acceptance, :execution_mode}}

  defp worker_placement(session_id) do
    case Repo.one(
           from(value in Placement,
             where: value.session_id == ^session_id,
             order_by: [desc: value.generation, desc: value.inserted_at],
             limit: 1
           )
         ) do
      %Placement{} = placement ->
        %{
          generation: placement.generation,
          state: placement.state,
          worker_id: placement.worker_id
        }

      nil ->
        nil
    end
  end

  defp valid_worker_placement?(nil), do: true

  defp valid_worker_placement?(%{generation: generation, state: state, worker_id: worker_id}) do
    is_integer(generation) and generation > 0 and is_atom(state) and is_binary(worker_id) and
      String.trim(worker_id) != ""
  end

  defp valid_worker_placement?(_placement), do: false

  defp exact_delivery(snapshot, settings, root_message_ref) do
    expected_conversation = "slack:#{settings.workspace_ref}:#{settings.channel_ref}"
    receipt = snapshot.external_receipt

    if receipt["transport"] == "slack" and
         receipt["conversation_ref"] == expected_conversation and
         receipt["thread_ref"] == root_message_ref and
         is_binary(receipt["message_ref"]) and String.trim(receipt["message_ref"]) != "" and
         is_binary(receipt["delivery_ref"]) and String.trim(receipt["delivery_ref"]) != "" do
      :ok
    else
      {:error, :live_acceptance_delivery_misrouted}
    end
  end

  defp utc_now(function) do
    case function.() do
      %DateTime{} = now -> {:ok, DateTime.shift_zone!(now, "Etc/UTC")}
      _invalid -> {:error, {:invalid_live_acceptance, :clock}}
    end
  end

  defp slack_timestamp(now, sequence) do
    microseconds = DateTime.to_unix(now, :microsecond) + sequence
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  defp generated_run_id do
    "live-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  defp release_version do
    case Application.spec(:ryker, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp reference(value, _field)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_live_acceptance, :reference}}
  end

  defp reference(_value, field), do: {:error, {:invalid_live_acceptance, field}}

  defp string_keys(report),
    do: Map.new(report, fn {key, value} -> {Atom.to_string(key), value} end)
end
