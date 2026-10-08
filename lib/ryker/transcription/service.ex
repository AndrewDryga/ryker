defmodule Ryker.Transcription.Service do
  @moduledoc """
  Transcribes a recording on whisper.cpp servers outside Ryker's container,
  such as whisper large-v3 on the Mac's GPU (`scripts/voice-service.sh`).

  Andrew's voice message of 2026-09-28 switched from Ukrainian to English to
  Spanish and back; Ryker's own small model wrote it as Russian and
  Portuguese, and he asked for voice to work reliably. On the Mac, large-v3
  wrote every part in the language he spoke, in about 20 seconds for 33
  seconds of speech, once each part's language was chosen among the languages
  people speak here (`Ryker.Transcription.Languages`).

  Two servers, because whisper.cpp's server either writes words or, started
  with `-dl`, only detects the language, fast: `RYKER_WHISPER_DETECT_URL`
  gives whisper's language probabilities for the whole recording and for each
  part, and `RYKER_WHISPER_URL` writes each part in the language chosen for
  it. The recording is converted and cut at its pauses in the container, as
  Ryker's own model does (`Ryker.Transcription.Local.with_parts/3`), and each
  part goes to the servers as 16 kHz WAV. Every request is bounded in time and
  in the size of its answer.

  A recording has `Ryker.Transcription.recording_seconds/0` whichever model
  reads it. When the servers cannot be reached, answer with an error or with
  something Ryker cannot read, or stop answering, Ryker's own model reads the
  recording in the time left, so a voice message is never lost to a stopped
  or changed service; the log says why.
  """
  @behaviour Ryker.Transcription
  alias Ryker.Crypto
  alias Ryker.Delivery.HTTPClient
  alias Ryker.Transcription
  alias Ryker.Transcription.{Languages, Local}
  require Logger

  # One request answers in 1.4 to 5.4 s on an M3 Pro; one still going after
  # half a minute is stuck, and Ryker's own model gets the time left.
  @request_timeout_ms 30_000
  @maximum_response_bytes 1_024 * 1_024

  @impl true
  def transcribe(data, options \\ [])

  def transcribe(data, options) when is_binary(data) and data != "" and is_list(options) do
    settings = settings(options)
    deadline = System.monotonic_time(:millisecond) + settings.timeout_ms

    if url?(settings.url) and url?(settings.detect_url) do
      case Local.with_parts(data, options, &read(&1, &2, settings, deadline)) do
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
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        settings.fallback.transcribe(data, Keyword.put(options, :timeout_ms, remaining))

      _spent ->
        {:error, :timeout}
    end
  end

  @doc false
  # The words of a prepared recording: its whole file's path and its parts'.
  @spec read(String.t(), [String.t()], map(), integer()) ::
          Transcription.result() | {:error, {:service, String.t()}}
  def read(wav, parts, settings, deadline) do
    with {:ok, whole} <- detect(settings, wav, deadline),
         main = Languages.main(whole, settings.languages),
         {:ok, texts} <- read_parts(parts, main, settings, deadline) do
      case Transcription.words(Enum.join(texts, "\n")) do
        {:ok, words} -> {:ok, words}
        :error -> {:error, :no_speech}
      end
    end
  end

  defp read_parts(parts, main, settings, deadline) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, texts} ->
      with {:ok, probabilities} <- detect(settings, part, deadline),
           language = Languages.part(probabilities, main, settings.languages) || "auto",
           {:ok, text} <- write(settings, part, language, deadline) do
        {:cont, {:ok, [text | texts]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, Enum.reverse(texts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detect(settings, path, deadline) do
    case post(settings, settings.detect_url, path, "auto", deadline) do
      {:ok, %{"language_probabilities" => probabilities}} when is_map(probabilities) ->
        {:ok, probabilities}

      {:ok, _answer} ->
        {:error, {:service, "answered without language probabilities"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write(settings, path, language, deadline) do
    case post(settings, settings.url, path, language, deadline) do
      {:ok, %{"text" => text}} when is_binary(text) -> {:ok, text}
      {:ok, _answer} -> {:error, {:service, "answered without words"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post(settings, base, path, language, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0 || {:error, {:service, "ran out of time"}},
         {:ok, audio} <- read_file(path) do
      fields = [{"language", language}, {"response_format", "verbose_json"}]
      settings.request.(inference(base), fields, audio, min(remaining, @request_timeout_ms))
    end
  end

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
      HTTPClient.build(
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
          HTTPClient.stream(
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

  @doc false
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
      request: Keyword.get(options, :request, &request/4),
      timeout_ms:
        Keyword.get_lazy(options, :timeout_ms, fn ->
          Transcription.recording_seconds() * 1_000
        end),
      url: Keyword.get_lazy(options, :url, fn -> System.get_env("RYKER_WHISPER_URL") end)
    }
  end
end
