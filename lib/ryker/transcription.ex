defmodule Ryker.Transcription do
  @moduledoc """
  What a person said in a voice message or a video, as text the routing and
  Work models read.

  A transcriber takes a recording's bytes and returns its words. Every
  recording is bounded the same way wherever it came from: at most
  `maximum_bytes/0` and `maximum_seconds/0` long, and a transcriber gives up
  after its own time limit. `Ryker.Transcription.Local` runs inside Ryker's
  container; tests use a stand-in that runs no model.

  A recording's file descriptor carries the outcome beside the stored file:
  `"transcript"` with the words, or `"transcript_unavailable"` saying plainly
  why there are none, so a voice message reaches routing as words or as a
  voice message Ryker could not transcribe, never as an unreadable file.
  """

  @maximum_bytes 8 * 1_024 * 1_024
  @maximum_seconds 300
  # Five minutes of fast speech is about 5 KB of text.
  @maximum_transcript_bytes 8_192
  @outcome_fields ~w(transcript transcript_pending transcript_unavailable)

  @type failure :: :too_large | :too_long | :no_speech | :timeout | :unavailable | :failed

  @callback transcribe(data :: binary(), options :: keyword()) ::
              {:ok, String.t()} | {:error, failure()}

  @doc """
  The transcriber Slack and Chat use: the local one, or the stand-in the test
  configuration names, so no test runs a model.
  """
  @spec transcriber() :: module()
  def transcriber, do: Application.get_env(:ryker, :transcriber, Ryker.Transcription.Local)

  @spec maximum_bytes() :: pos_integer()
  def maximum_bytes, do: @maximum_bytes

  @spec maximum_seconds() :: pos_integer()
  def maximum_seconds, do: @maximum_seconds

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
  @spec outcome(String.t(), {:ok, String.t()} | {:error, failure()}) :: map()
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
