defmodule Ryker.WorkExamples.Worker do
  @moduledoc """
  Copies settled Work turns into the training set (`Ryker.WorkExamples`). It
  runs only while keeping work examples is on (Settings › Data retention),
  and only where Work runs.

  A turn is copied once its request comes to rest, which every request
  announces as it changes, so a change wakes the worker at once. Feedback
  about a request wakes it too, to copy the new signal beside the request's
  examples (`Ryker.WorkExamples.copy_feedback/0`). With nothing to copy it
  sleeps for its safety-net interval.
  """
  use Ryker.PollingWorker, lane: :work_examples, interval: :poll_interval_ms

  alias Ryker.{Episodes, Feedback, Options, PollingWorker, WorkExamples}

  @fields [:batch_size, :poll_interval_ms, :redaction_secrets, :window_seconds]

  @spec child_spec(keyword() | map()) :: Supervisor.child_spec()
  def child_spec(configuration) do
    _options = options!(configuration)
    %{id: __MODULE__, start: {__MODULE__, :start_link, [configuration]}}
  end

  def start_link(configuration),
    do: GenServer.start_link(__MODULE__, configuration, name: __MODULE__)

  @impl PollingWorker
  def setup(configuration), do: {:ok, options!(configuration)}

  @impl PollingWorker
  def wake_on(_options), do: [&Episodes.subscribe_episodes/0, &Feedback.subscribe_feedback/0]

  @impl PollingWorker
  def poll(options) do
    case WorkExamples.capture(options) do
      {:ok, %{copied: copied, forgotten: forgotten}}
      when copied + forgotten >= options.batch_size ->
        0

      {:ok, _pass} ->
        PollingWorker.idle_interval_ms()
    end
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(configuration) do
    options =
      Options.normalize!(configuration, @fields, @fields,
        list: "work example configuration must use unique known fields",
        map: "work example configuration has missing or unknown fields",
        other: "work example configuration must be a map or keyword list"
      )

    valid =
      Enum.all?(
        [:batch_size, :poll_interval_ms, :window_seconds],
        &(is_integer(options[&1]) and options[&1] > 0)
      ) and is_list(options.redaction_secrets) and
        Enum.all?(options.redaction_secrets, &is_binary/1)

    unless valid,
      do: raise(ArgumentError, "work example configuration is outside its safe bounds")

    options
  end
end
