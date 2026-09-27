defmodule Ryker.TestTranscriber do
  @moduledoc """
  Deterministic speech to text for tests: no model runs.

  `recording/2` makes the bytes of a recording in a real container (so the
  artifact store keeps it) that "says" the given words; `"FAIL"` makes
  transcription fail and `"TOO LONG"` makes the recording longer than Ryker
  transcribes. Every call tells the calling process, so a test can prove a
  recording was, or was not, transcribed.
  """

  @behaviour Ryker.Transcription

  @marker "RYKER-TEST-WORDS:"
  # The first box of an .m4a file, as Slack and phones write it.
  @m4a <<0, 0, 0, 24, "ftypM4A ", 0, 0, 2, 0, "M4A isom">>
  # The EBML header a browser's recording starts with.
  @webm <<0x1A, 0x45, 0xDF, 0xA3>>

  @spec recording(String.t(), :m4a | :webm) :: binary()
  def recording(words, container \\ :m4a)
  def recording(words, :m4a), do: @m4a <> @marker <> words
  def recording(words, :webm), do: @webm <> @marker <> words

  @impl true
  def transcribe(data, _options) do
    send(self(), {:transcribed, data})

    case :binary.split(data, @marker) do
      [_audio, "FAIL"] -> {:error, :failed}
      [_audio, "TOO LONG"] -> {:error, :too_long}
      [_audio, words] -> {:ok, words}
      [_audio] -> {:error, :no_speech}
    end
  end
end
