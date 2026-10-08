defmodule Ryker.RoutingExamples.Worker do
  @moduledoc """
  Copies settled routing decisions into the training set
  (`Ryker.RoutingExamples`). It runs only while keeping routing examples is on
  (Settings › Data retention).

  A decision settles when a message is routed, when the Work it started comes
  to rest, or when a quick reply or reaction it chose is delivered; each is
  announced, a delivery as its message changing, and wakes the worker at once.
  Feedback about a request wakes it too, to copy the new signal beside the
  request's examples (`Ryker.RoutingExamples.copy_feedback/0`).
  Nothing settles by the clock alone, so with nothing to copy it sleeps for
  its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :routing_examples, interval: :poll_interval_ms
  alias Ryker.{Episodes, Feedback, Options, PollingWorker, RoutingExamples, TrainingExamples}
  alias Ryker.Ingress

  @fields [:batch_size, :poll_interval_ms, :window_seconds]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration),
    do: GenServer.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl PollingWorker
  def setup(configuration), do: {:ok, Map.put(options!(configuration), :failures, %{})}

  @impl PollingWorker
  def wake_on(_options),
    do: [
      &Ingress.Inbox.subscribe_inputs/0,
      &Episodes.subscribe_episodes/0,
      &Feedback.subscribe_feedback/0
    ]

  @impl PollingWorker
  # A copy that keeps failing is passed over after a few passes, so it cannot
  # hold back the copies after it (`Ryker.TrainingExamples.failures/2`).
  def poll(options) do
    skip = TrainingExamples.passed_over(options.failures)
    {:ok, pass} = RoutingExamples.capture(Map.put(options, :skip, skip))
    failures = TrainingExamples.failures(options.failures, pass.failed)

    if pass.copied + pass.forgotten >= options.batch_size,
      do: {0, %{options | failures: failures}},
      else: {PollingWorker.idle_interval_ms(), %{options | failures: failures}}
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    options =
      Options.normalize!(configuration, @fields, @fields,
        list: "routing example configuration must use unique known fields",
        map: "routing example configuration has missing or unknown fields",
        other: "routing example configuration must be a map or keyword list"
      )

    valid =
      Enum.all?(
        [:batch_size, :poll_interval_ms, :window_seconds],
        &(is_integer(options[&1]) and options[&1] > 0)
      )

    unless valid,
      do: raise(ArgumentError, "routing example configuration is outside its safe bounds")

    options
  end
end
