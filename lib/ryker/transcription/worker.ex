defmodule Ryker.Transcription.Worker do
  @moduledoc """
  Transcribes each voice message or video after its message is recorded.

  The Slack gateway keeps a recording and records its message with the
  transcript pending, so Slack hears its acknowledgement at once, and routing
  waits for the words (`Ryker.Ingress.Inbox`). This worker takes the waiting
  messages in the order they arrived and transcribes their recordings one at
  a time, each bounded as `Ryker.Transcription` says: whisper uses every core
  it is given, so two at once finish no sooner. It fills in what was said, or
  why there is nothing, and that wakes routing.

  A recording's transcript is kept beside it, so the same Slack file, shared
  again or edited, is read from what was kept instead of transcribed again.

  Recording a message announces it, which wakes the worker at once; otherwise
  it sleeps for the safety-net interval.
  """
  use Ryker.PollingWorker, lane: :transcription, interval: :poll_interval_ms
  alias Ryker.Artifacts
  alias Ryker.Ingress
  alias Ryker.PollingWorker
  alias Ryker.Transcription
  require Logger

  @failures [:too_large, :too_long, :no_speech, :timeout, :unavailable, :failed]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    {name, options} = Keyword.pop(options, :name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl PollingWorker
  def setup(options) do
    case settings(options) do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl PollingWorker
  def wake_on(_state), do: [&Ingress.Inbox.subscribe_inputs/0]

  @impl PollingWorker
  def poll(state) do
    case transcribe_next(state) do
      :idle ->
        state.idle_interval_ms

      {:ok, _outcome} ->
        0

      {:error, reason} ->
        Logger.warning("voice message transcription not saved: #{inspect(reason)}")
        state.poll_interval_ms
    end
  end

  @doc """
  Transcribes the oldest message still waiting for its transcript and fills
  in the words: `:transcribed`, or `:released` when routing stopped waiting
  first. `:idle` when no message is waiting.
  """
  @spec transcribe_next(keyword() | map()) ::
          :idle | {:ok, :transcribed | :released} | {:error, term()}
  def transcribe_next(options) do
    with {:ok, settings} <- settings(options) do
      case Ingress.Inbox.fetch_waiting_for_transcript() do
        {:ok, entry} -> transcribe_entry(entry, settings)
        {:error, :not_found} -> :idle
      end
    end
  end

  defp transcribe_entry(entry, settings) do
    results =
      entry.content
      |> Transcription.pending_files()
      |> Map.new(fn file -> {file["artifact_ref"], transcribe(file, settings)} end)

    Ingress.Inbox.transcribed(Ingress.Inbox.ref(entry), results)
  end

  defp transcribe(%{"artifact_ref" => ref}, settings) when is_binary(ref) do
    case Artifacts.fetch_many([ref]) do
      {:ok, [recording]} -> kept_or_transcribed(recording, settings)
      {:error, _reason} -> {:error, :failed}
    end
  end

  defp transcribe(_file, _settings), do: {:error, :failed}

  defp kept_or_transcribed(recording, settings) do
    kept = recording.source_ref <> ":transcript"

    case Artifacts.fetch_source(recording.source_kind, kept) do
      {:ok, %{data: words}} ->
        {:ok, words}

      {:error, :input_artifact_not_found} ->
        result = run(settings.transcriber, recording.data)
        _kept = keep(recording.source_kind, kept, result)
        result
    end
  end

  # A transcriber that raises or answers out of contract is a recording Ryker
  # could not transcribe, never a worker that stops for every later message.
  defp run(transcriber, data) do
    case transcriber.transcribe(data, []) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, failure} when failure in @failures -> {:error, failure}
      _other -> {:error, :failed}
    end
  rescue
    error ->
      Logger.warning("voice message transcriber failed: #{inspect(error.__struct__)}")
      {:error, :failed}
  catch
    kind, _reason ->
      Logger.warning("voice message transcriber failed: #{kind}")
      {:error, :failed}
  end

  defp keep(source_kind, source_ref, {:ok, text}) do
    with {:ok, words} <- Transcription.words(text) do
      Artifacts.put(%{
        data: words,
        media_type: "text/plain",
        name: "transcript.txt",
        source_kind: source_kind,
        source_ref: source_ref
      })
    end
  end

  defp keep(_source_kind, _source_ref, {:error, _failure}), do: :ok

  defp settings(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: options |> Map.new() |> settings(),
      else: {:error, {:invalid_transcription_worker, :options}}
  end

  defp settings(%{transcriber: transcriber} = options) do
    settings = %{
      idle_interval_ms: Map.get(options, :idle_interval_ms, PollingWorker.idle_interval_ms()),
      poll_interval_ms: Map.get(options, :poll_interval_ms, 1_000),
      transcriber: transcriber
    }

    if transcriber?(transcriber) and positive?(settings.idle_interval_ms) and
         positive?(settings.poll_interval_ms),
       do: {:ok, settings},
       else: {:error, {:invalid_transcription_worker, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_transcription_worker, :options}}

  defp transcriber?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and
      function_exported?(module, :transcribe, 2)
  end

  defp positive?(value), do: is_integer(value) and value > 0
end
