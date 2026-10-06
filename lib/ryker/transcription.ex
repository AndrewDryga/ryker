defmodule Ryker.Transcription do
  @moduledoc """
  What a person said in a voice message or a video, as text the routing and
  Work models read.

  A transcriber takes a recording's bytes and returns its words. Every
  recording is bounded the same way wherever it came from: at most
  `maximum_bytes/0` and `maximum_seconds/0` long, read in
  `recording_seconds/0` whichever model reads it. `Ryker.Transcription.Service`
  sends it to whisper servers outside the container when they are configured
  (large-v3 on the Mac's GPU, `scripts/voice-service.sh`), and
  `Ryker.Transcription.Local` runs Ryker's own small model inside the
  container otherwise, or in the time left when those servers fail. Tests use
  a stand-in that runs no model.

  A recording's file descriptor carries the outcome beside the stored file:
  `"transcript"` with the words, or `"transcript_unavailable"` saying plainly
  why there are none, so a voice message reaches routing as words or as a
  voice message Ryker could not transcribe, never as an unreadable file.

  A Slack voice message is recorded before it is transcribed, so Slack hears
  its acknowledgement at once: its descriptor says `"transcript_pending"`
  until `Ryker.Transcription.Worker` settles it (`settle/2`), and routing
  waits for that, for `wait_seconds/0` at most (`Ryker.Ingress.Inbox`).
  """

  @maximum_bytes 8 * 1_024 * 1_024
  @maximum_seconds 300
  # Five minutes of fast speech is about 5 KB of text.
  @maximum_transcript_bytes 8_192
  # A recording gets a minute and a half whichever model reads it: whisper
  # large-v3 on an M3 Pro read five minutes of speech in 67 s, past the
  # minute this once was. A Slack message holds at most two recordings, so a
  # transcript not ready in three minutes is not coming.
  @recording_seconds 90
  @wait_seconds 2 * @recording_seconds
  @outcome_fields ~w(transcript transcript_pending transcript_unavailable)

  @type failure :: :too_large | :too_long | :no_speech | :timeout | :unavailable | :failed
  @type result :: {:ok, String.t()} | {:error, failure()}

  @callback transcribe(data :: binary(), options :: keyword()) :: result()

  @doc """
  The transcriber Slack and Chat use: whisper servers when they are
  configured, else Ryker's own model, or the stand-in the test configuration
  names, so no test runs a model.
  """
  @spec transcriber() :: module()
  def transcriber, do: Application.get_env(:ryker, :transcriber, Ryker.Transcription.Service)

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec maximum_seconds() :: pos_integer()
  def maximum_seconds, do: @maximum_seconds

  @doc "How long one recording may take to read, whichever model reads it."
  @spec recording_seconds() :: pos_integer()
  def recording_seconds, do: @recording_seconds

  @doc "How long routing waits for a recording's transcript before it reads that there is none."
  @spec wait_seconds() :: pos_integer()
  def wait_seconds, do: @wait_seconds

  @doc "The descriptor field of a recording kept before it is transcribed."
  @spec pending() :: map()
  def pending, do: %{"transcript_pending" => true}

  @doc "Whether any recording in a message's content is still waiting for its transcript."
  @spec pending?(term()) :: boolean()
  def pending?(content), do: pending_files(content) != []

  @doc "The descriptors of the recordings in a message's content still waiting for a transcript."
  @spec pending_files(term()) :: [map()]
  def pending_files(%{"files" => files}) when is_list(files),
    do: Enum.filter(files, &(&1["transcript_pending"] == true))

  def pending_files(_content), do: []

  @doc """
  A message's content with each recording still waiting for its transcript
  given the outcome of `result`, called with that recording's descriptor.
  """
  @spec settle(map(), (map() -> result())) :: map()
  def settle(%{"files" => files} = content, result) when is_list(files) do
    settled =
      Enum.map(files, fn
        %{"transcript_pending" => true} = file ->
          file
          |> Map.delete("transcript_pending")
          |> Map.merge(outcome(file["media_type"], result.(file)))

        file ->
          file
      end)

    %{content | "files" => settled}
  end

  def settle(content, _result), do: content

  @doc """
  A file descriptor without what Ryker made of its recording: the transcript,
  why there is none, or that it is still to come.
  """
  @spec without_outcome(term()) :: term()
  def without_outcome(%{} = file), do: Map.drop(file, @outcome_fields)
  def without_outcome(file), do: file

  @doc """
  The descriptor fields for a recording's transcription outcome: its words,
  or why there are none.
  """
  @spec outcome(String.t(), result()) :: map()
  def outcome(media_type, {:ok, text}) do
    case words(text) do
      {:ok, words} -> %{"transcript" => words}
      :error -> outcome(media_type, {:error, :no_speech})
    end
  end

  def outcome(media_type, {:error, failure}),
    do: %{"transcript_unavailable" => unavailable(media_type, failure)}

  @doc """
  Why a recording has no transcript, in words a person and a model both read:
  "a voice message longer than 5 minutes, the most Ryker transcribes".
  """
  @spec unavailable(String.t(), failure()) :: String.t()
  def unavailable(media_type, :too_long),
    do: "#{kind(media_type)} longer than #{minutes()} minutes, the most Ryker transcribes"

  def unavailable(media_type, :too_large),
    do: "#{kind(media_type)} larger than #{megabytes()} MB, the most Ryker transcribes"

  def unavailable(media_type, _failure), do: "#{kind(media_type)} Ryker could not transcribe"

  @doc """
  A transcript as one bounded line of text: segments joined by spaces,
  silence markers removed. Empty or unreadable text is no transcript.
  """
  @spec words(term()) :: {:ok, String.t()} | :error
  def words(text) when is_binary(text) do
    if String.valid?(text) and :binary.match(text, <<0>>) == :nomatch do
      text
      |> String.replace(~r/\[BLANK_AUDIO\]/, " ")
      |> String.split()
      |> Enum.join(" ")
      |> bounded()
    else
      :error
    end
  end

  def words(_text), do: :error

  defp bounded(""), do: :error

  defp bounded(words) when byte_size(words) <= @maximum_transcript_bytes, do: {:ok, words}

  defp bounded(words) do
    kept = words |> String.byte_slice(0, @maximum_transcript_bytes - 3) |> String.trim_trailing()
    {:ok, kept <> "…"}
  end

  defp kind("video/" <> _format), do: "a video"
  defp kind(_media_type), do: "a voice message"

  defp minutes, do: div(@maximum_seconds, 60)
  defp megabytes, do: div(@maximum_bytes, 1_024 * 1_024)
end
