defmodule Ryker.Evals.WorldInputs do
  @moduledoc """
  Turns a scenario's declared events into what one model-world run feeds the
  host: the ordered inputs, the ingress `Input` each becomes with its receipt
  time rebased onto the live clock, the channel memberships correlation needs,
  and the evaluation-only delivery adapters that settle visible output.
  """

  alias Ryker.Delivery.Adapters

  alias Ryker.Evals.{
    GitHubDeliveryPublisher,
    LabDeliveryPublisher,
    SlackDeliveryPublisher,
    WorldCase
  }

  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership

  @doc """
  The scenario's inputs in execution order: its initial `input` events
  followed by its scheduled wait wakeups, each checked against the declared
  actors.
  """
  @spec input_events(WorldCase.t()) :: {:ok, [map()]} | {:error, term()}
  def input_events(%WorldCase{actors: actors} = scenario) do
    inputs = scenario_inputs(scenario)
    actor_refs = MapSet.new(actors, & &1["actor_ref"])

    cond do
      inputs == [] ->
        {:error, {:invalid_world_runner, :initial_input}}

      not Enum.all?(inputs, &input_actor?(&1, actor_refs)) ->
        {:error, {:invalid_world_runner, :input_actor}}

      true ->
        {:ok, inputs}
    end
  end

  @doc false
  @spec scenario_inputs(WorldCase.t()) :: [map()]
  def scenario_inputs(%WorldCase{} = scenario) do
    initial = Enum.filter(scenario.events, &(&1["kind"] == "input"))

    initial ++ scenario.world["scheduled_events"]
  end

  # Correlation only reaches conversations Ryker has actually joined, so a
  # scenario that reports one incident in two channels has to declare that
  # membership. It is evaluation-world setup, not permission: the channels are
  # exactly the ones the scenario's own inputs arrive in, and every one of them
  # is an ordinary non-private, non-shared channel.
  @spec join_scenario_channels([map()], DateTime.t()) :: :ok
  def join_scenario_channels(inputs, now) do
    inputs
    |> Enum.flat_map(&scenario_channel/1)
    |> Enum.uniq()
    |> Enum.each(fn {workspace_ref, channel_ref} ->
      Repo.insert!(
        %ChannelMembership{
          id: Ecto.UUID.generate(),
          workspace_ref: workspace_ref,
          channel_ref: channel_ref,
          private: false,
          external_shared: false,
          generation: 1,
          status: :joined,
          joined_at: now,
          inserted_at: now,
          updated_at: now
        },
        on_conflict: :nothing,
        conflict_target: [:workspace_ref, :channel_ref]
      )
    end)

    :ok
  end

  @doc """
  Builds the ingress input for one scenario event. Only receipt timing is
  rebased onto the live world clock; the original source chronology travels
  with the content as `world_replay_clock`.
  """
  @spec world_input(map(), pos_integer(), WorldCase.t(), String.t(), DateTime.t(), map()) ::
          {:ok, Input.t()} | {:error, term()}
  def world_input(event, index, scenario, identity, world_started_at, content) do
    actor = Enum.find(scenario.actors, &(&1["actor_ref"] == event["actor_ref"]))

    with %{"input_profile" => profile} <- actor,
         {:ok, source_occurred_at, 0} <- DateTime.from_iso8601(event["occurred_at"]),
         {:ok, clock_started_at, 0} <- DateTime.from_iso8601(scenario.clock["start"]),
         rebased_at <-
           DateTime.add(
             world_started_at,
             DateTime.diff(source_occurred_at, clock_started_at, :microsecond),
             :microsecond
           ),
         occurred_at <-
           max_datetime(rebased_at, DateTime.add(Repo.now!(), 1, :microsecond)),
         {:ok, destination} <- input_destination(event),
         {:ok, actor_kind} <- input_atom(profile["actor"]["kind"], :actor_kind),
         {:ok, event_kind} <- input_atom(profile["event_kind"], :event_kind),
         {:ok, occurred_at_source} <-
           input_atom(profile["occurred_at_source"], :occurred_at_source),
         {:ok, content} <- world_replay_content(content, event, occurred_at, occurred_at_source) do
      Input.new(%{
        actor: %{kind: actor_kind, ref: profile["actor"]["ref"]},
        content: content,
        destination: destination,
        event_kind: event_kind,
        event_ref: "world-event:#{scenario.id}:#{identity}:#{index}",
        native_input_id: "world-input:#{scenario.id}:#{identity}:#{index}",
        occurred_at: occurred_at,
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: profile["source"]["kind"], ref: profile["source"]["ref"]},
        source_capabilities: profile["source_capabilities"],
        source_item_ref: source_item_ref(profile, event, source_occurred_at, scenario.id, index)
      })
    else
      nil -> {:error, {:invalid_world_runner, :input_actor}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_world_runner, :input_profile}}
    end
  end

  @doc false
  @spec max_datetime(DateTime.t(), DateTime.t()) :: DateTime.t()
  def max_datetime(left, right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  @doc false
  @spec eval_adapters(pid()) :: {:ok, map()} | {:error, term()}
  def eval_adapters(agent) do
    Adapters.new(%{
      "control_plane" => %{
        binding: agent,
        message_publisher: LabDeliveryPublisher,
        reaction_publisher: LabDeliveryPublisher
      },
      "github" => %{
        binding: agent,
        message_publisher: GitHubDeliveryPublisher,
        reaction_publisher: GitHubDeliveryPublisher
      },
      "slack" => %{
        binding: agent,
        message_publisher: SlackDeliveryPublisher,
        reaction_publisher: SlackDeliveryPublisher
      }
    })
  end

  @doc false
  @spec delivery_state(WorldCase.t()) :: map()
  def delivery_state(scenario) do
    lose_next_response =
      scenario.host_replay["model_events"]
      |> Enum.flat_map(&Map.get(&1, "faults", []))
      |> Enum.count(&(&1 == "lose_delivery_response"))

    %{
      deliveries: %{},
      lose_next_response: lose_next_response,
      order: [],
      receipts: %{}
    }
  end

  defp scenario_channel(%{
         "kind" => "input",
         "destination" => %{"transport" => "slack", "conversation_ref" => reference}
       }) do
    case String.split(reference, ":", parts: 3) do
      ["slack", workspace_ref, "C" <> _ = channel_ref] -> [{workspace_ref, channel_ref}]
      _other -> []
    end
  end

  defp scenario_channel(_event), do: []

  defp input_actor?(%{"kind" => "wait_wakeup", "occurred_at" => occurred_at} = event, _refs),
    do: map_size(event) == 2 and is_binary(occurred_at)

  defp input_actor?(%{"kind" => "input", "actor_ref" => actor_ref}, refs),
    do: MapSet.member?(refs, actor_ref)

  defp input_actor?(_event, _refs), do: false

  defp world_replay_content(content, event, received_at, occurred_at_source) do
    if Map.has_key?(content, "world_replay_clock") do
      {:error, {:invalid_world_runner, :reserved_input_metadata}}
    else
      clock = %{
        "host_received_at" => DateTime.to_iso8601(received_at),
        "mode" => "simulated",
        "note" =>
          "Only receipt timing is rebased to exercise live host waits. Use the original source time for event chronology. Original source content and tool observations retain their historical dates; this replay supplies no present-day health proof.",
        "scenario_occurred_at" => event["occurred_at"],
        "scenario_occurred_at_source" => Atom.to_string(occurred_at_source),
        "source_occurred_at" => if(occurred_at_source == :source, do: event["occurred_at"])
      }

      {:ok, Map.put(content, "world_replay_clock", clock)}
    end
  end

  defp source_item_ref(
         _profile,
         %{"source_item_ref" => source_item_ref},
         _occurred_at,
         _id,
         _index
       ),
       do: source_item_ref

  defp source_item_ref(
         %{"source_capabilities" => capabilities},
         _event,
         _occurred_at,
         _id,
         _index
       )
       when map_size(capabilities) == 0,
       do: nil

  defp source_item_ref(
         %{"source" => %{"kind" => "slack"}},
         _event,
         occurred_at,
         _id,
         _index
       ),
       do: slack_timestamp(occurred_at)

  defp source_item_ref(%{"source" => %{"kind" => "github"}}, _event, _occurred_at, _id, _index),
    do: nil

  defp source_item_ref(
         %{"source" => %{"kind" => "control_plane"}},
         _event,
         _occurred_at,
         scenario_id,
         index
       ),
       do: "control-plane-item:#{scenario_id}:#{index}"

  defp source_item_ref(_profile, _event, _occurred_at, scenario_id, index),
    do: "world-source-item:#{scenario_id}:#{index}"

  defp slack_timestamp(occurred_at) do
    microseconds = DateTime.to_unix(occurred_at, :microsecond)
    seconds = div(microseconds, 1_000_000)
    fraction = microseconds |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{fraction}"
  end

  # The profile vocabulary has one owner, `WorldCase`; the runner only names
  # which profile field it could not read.
  defp input_atom(value, field) do
    case WorldCase.profile_atom(value, field) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_world_runner, field}}
    end
  end

  defp input_destination(%{
         "destination" => %{
           "conversation_ref" => conversation_ref,
           "thread_ref" => thread_ref,
           "transport" => transport
         }
       })
       when is_binary(conversation_ref) and (is_binary(thread_ref) or is_nil(thread_ref)) and
              transport in ~w(slack github control_plane) do
    {:ok, %{conversation_ref: conversation_ref, thread_ref: thread_ref, transport: transport}}
  end

  defp input_destination(%{"destination" => _invalid}),
    do: {:error, {:invalid_world_runner, :destination}}

  defp input_destination(_input), do: {:error, {:invalid_world_runner, :destination}}
end
