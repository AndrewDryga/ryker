defmodule Ryker.Transcription.Service do
  @moduledoc """
  Transcribes a recording on whisper.cpp servers beside Ryker's container:
  Compose's `whisper` and `whisper-detect` on the CPU, or whisper large-v3 on
  a Mac's GPU (`scripts/voice-service.sh`).

  Andrew's voice message of 2026-09-28 switched from Ukrainian to English to
  Spanish and back; Ryker's own small model wrote it as Russian and
  Portuguese, and he asked for voice to work reliably. On the Mac, large-v3
  wrote every part in the language he spoke, in about 20 seconds for 33
  seconds of speech, once each part's language was chosen among the languages
  people speak here (`Ryker.Transcription.Languages`).

  Two servers, because whisper.cpp's server either writes words or, started
  with `-dl`, only detects the language, fast: `RYKER_WHISPER_DETECT_URL`
  gives whisper's language probabilities for the whole recording and for each
  part, and `RYKER_WHISPER_URL` writes the words. The recording is converted
  and cut at its pauses in the container, as Ryker's own model does
  (`Ryker.Transcription.Local.with_parts/3`), and audio goes to the servers as
  16 kHz WAV. Every request is bounded in time and in the size of its answer.

  Reading each part in its own language costs a detection per part: about
  1.4 s on the Mac's GPU, 3 s with the small model on the CPU. Only a team
  that names several languages in `RYKER_VOICE_LANGUAGES` has use for it;
  anywhere else the recording is read in the language of the whole.

  Neighbouring parts read in the same language are written together, up to
  whisper's 30-second window. whisper reads 30 seconds at a time however short
  the audio, and on the CPU each of those passes costs large-v3-turbo about
  15 seconds: written part by part, a 33-second message took six passes and
  ran past the recording's time, while written by language it takes one pass
  for each language heard in turn.

  A recording has `Ryker.Transcription.recording_seconds/0` whichever model
  reads it. The servers get three quarters of it, which on the CPU is enough
  for about a minute of speech. When they cannot be reached, answer with an
  error or with something Ryker cannot read, stop answering, or run out of
  their time, Ryker's own model reads the recording in the time left, so a
  voice message is never lost to a stopped, changed or slow service; the log
  says why.
  """
  @behaviour Ryker.Transcription
  alias Ryker.Crypto
  alias Ryker.Delivery
  alias Ryker.Transcription
  alias Ryker.Transcription.{Languages, Local, Parts}
  require Logger

  # One request answers in 1.4 to 5.4 s on an M3 Pro's GPU, and in 3 s
  # (detecting) or 15 s (writing) on its CPU in Compose; one still going after
  # half a minute is stuck, and Ryker's own model gets the time left.
  @request_timeout_ms 30_000
  @maximum_response_bytes 1_024 * 1_024
  # whisper's window: 30 s of 16 kHz mono 16-bit samples.
  @window_bytes 30 * 16_000 * 2

  @impl true
  def transcribe(data, options \\ [])

  def transcribe(data, options) when is_binary(data) and data != "" and is_list(options) do
    settings = settings(options)
    deadline = settings.monotonic_ms.() + settings.timeout_ms
    servers_deadline = deadline - div(settings.timeout_ms, 4)

    if url?(settings.url) and url?(settings.detect_url) do
      case Local.with_parts(data, options, &read(&1, &2, settings, servers_deadline)) do
        {:error, {:service, reason}} ->
          Logger.warning("whisper service #{reason}; Ryker's own model reads the recording")
          fallback(data, options, settings, deadline)

        result ->
          result
      end
    else
      fallback(data, options, settings, deadline)
    end
  end

  def transcribe(_data, _options), do: {:error, :failed}

  defp fallback(data, options, settings, deadline) do
    case deadline - settings.monotonic_ms.() do
      remaining when remaining > 0 ->
        options = Keyword.put(options, :timeout_ms, remaining)
        settings.fallback.transcribe(data, options)

      _spent ->
        {:error, :timeout}
    end
  end

  @doc false
  # The words of a prepared recording: its whole file's path and its parts'.
  @spec read(String.t(), [String.t()], map(), integer()) ::
          Transcription.result() | {:error, {:service, String.t()}}
  def read(wav, parts, settings, deadline) do
    with {:ok, recording} <- read_file(wav),
         {:ok, whole} <- detect(settings, recording, deadline),
         main = Languages.main(whole, settings.languages),
         {:ok, heard} <- hear_parts(parts, whole, main, settings, deadline),
         {:ok, texts} <- each(runs(heard), &write(settings, &1, deadline)) do
      case Transcription.words(Enum.join(texts, "\n")) do
        {:ok, words} -> {:ok, words}
        :error -> {:error, :no_speech}
      end
    end
  end

  # Each part's language and samples. Parts are heard on their own only where
  # the team named several languages, and only when there are several: a
  # short message is one part, the whole recording.
  defp hear_parts(parts, whole, main, settings, deadline) do
    if length(settings.languages) > 1 and length(parts) > 1 do
      each(parts, &hear(&1, main, settings, deadline))
    else
      language = Languages.part(whole, main, settings.languages)
      each(parts, &in_language(&1, language))
    end
  end

  defp in_language(part, language) do
    with {:ok, audio} <- read_file(part),
         {:ok, pcm} <- samples(audio),
         do: {:ok, {language, pcm}}
  end

  # One part's language, heard on its own, and its samples.
  defp hear(part, main, settings, deadline) do
    with {:ok, audio} <- read_file(part),
         {:ok, pcm} <- samples(audio),
         {:ok, probabilities} <- detect(settings, audio, deadline) do
      {:ok, {Languages.part(probabilities, main, settings.languages), pcm}}
    end
  end

  # Parts are in order and cover every byte of the recording, so neighbours
  # joined are the recording between them, pauses included. A part whose
  # language was not heard is written on its own.
  defp runs(heard) do
    heard
    |> Enum.reduce([], fn
      {language, pcm}, [{language, run} | rest]
      when is_binary(language) and byte_size(run) + byte_size(pcm) <= @window_bytes ->
        [{language, run <> pcm} | rest]

      part, runs ->
        [part | runs]
    end)
    |> Enum.reverse()
  end

  # `function` on each item in order, or the first error.
  defp each(items, function) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, results} ->
      case function.(item) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp samples(audio) do
    case Parts.samples(audio) do
      {:ok, pcm} -> {:ok, pcm}
      :error -> {:error, :failed}
    end
  end

  defp detect(settings, audio, deadline) do
    case post(settings, settings.detect_url, audio, "auto", deadline) do
      {:ok, %{"language_probabilities" => probabilities}} when is_map(probabilities) ->
        {:ok, probabilities}

      {:ok, _answer} ->
        {:error, {:service, "answered without language probabilities"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(settings, {language, pcm}, deadline) do
    case post(settings, settings.url, Parts.wav(pcm), language || "auto", deadline) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, _answer} -> {:error, {:service, "answered without words"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(settings, base, audio, language, deadline) do
    case deadline - settings.monotonic_ms.() do
      remaining when remaining > 0 ->
        fields = [{"language", language}, {"response_format", "verbose_json"}]
        settings.request.(inference(base), fields, audio, min(remaining, @request_timeout_ms))

      _spent ->
        {:error, {:service, "ran out of time"}}
    end
  end

  # The WAV `Ryker.Transcription.Local` wrote in its own temporary directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.read(path) do
      {:ok, audio} -> {:ok, audio}
      {:error, _reason} -> {:error, :failed}
    end
  end

  @doc false
  # One multipart request to whisper.cpp's server: the WAV and its fields,
  # and the answer, or why there is none.
  @spec request(String.t(), [{String.t(), String.t()}], binary(), pos_integer()) ::
          {:ok, map()} | {:error, {:service, String.t()}}
  def request(url, fields, audio, timeout_ms) do
    boundary = "ryker-" <> Crypto.random_hex(12)

    request =
      Delivery.HTTPClient.build(
        :post,
        url,
        [
          {"accept", "application/json"},
          {"content-type", "multipart/form-data; boundary=" <> boundary}
        ],
        multipart(boundary, fields, audio)
      )

    task =
      Task.async(fn ->
        try do
          Delivery.HTTPClient.stream(
            request,
            Ryker.CoopFinch,
            timeout_ms + 1_000,
            @maximum_response_bytes
          )
        rescue
          error -> {:error, {:transport, error}}
        catch
          kind, reason -> {:error, {:transport, {kind, reason}}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{status: 200, body: body}}} -> decode(body)
      {:ok, {:ok, %{status: status}}} -> {:error, {:service, "answered #{status}"}}
      {:ok, {:error, _reason}} -> {:error, {:service, "could not be reached"}}
      _late_or_stopped -> {:error, {:service, "did not answer in #{div(timeout_ms, 1_000)} s"}}
    end
  end

  @doc """
  The multipart form one transcription request sends: each field, then the
  recording as a WAV file.
  """
  @spec multipart(String.t(), [{String.t(), String.t()}], binary()) :: iodata()
  def multipart(boundary, fields, audio) do
    [
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\n",
          ~s(Content-Disposition: form-data; name="),
          name,
          ~s("\r\n\r\n),
          value,
          "\r\n"
        ]
      end),
      "--",
      boundary,
      "\r\n",
      ~s(Content-Disposition: form-data; name="file"; filename="recording.wav"\r\n),
      "Content-Type: audio/wav\r\n\r\n",
      audio,
      "\r\n--",
      boundary,
      "--\r\n"
    ]
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = answer} -> {:ok, answer}
      _unreadable -> {:error, {:service, "answered what Ryker cannot read"}}
    end
  end

  defp inference(base), do: String.trim_trailing(base, "/") <> "/inference"

  defp url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  defp url?(_value), do: false

  defp settings(options) do
    %{
      detect_url:
        Keyword.get_lazy(options, :detect_url, fn ->
          System.get_env("RYKER_WHISPER_DETECT_URL")
        end),
      fallback: Keyword.get(options, :fallback, Local),
      languages: Keyword.get_lazy(options, :languages, fn -> Languages.configured() end),
      monotonic_ms:
        Keyword.get(options, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      request: Keyword.get(options, :request, &request/4),
      timeout_ms:
        Keyword.get_lazy(options, :timeout_ms, fn ->
          Transcription.recording_seconds() * 1_000
        end),
      url: Keyword.get_lazy(options, :url, fn -> System.get_env("RYKER_WHISPER_URL") end)
    }
  end
end
