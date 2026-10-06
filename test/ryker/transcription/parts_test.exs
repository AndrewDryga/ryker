defmodule Ryker.Transcription.PartsTest do
  @moduledoc """
  A recording is cut at its pauses so whisper hears each part in its own
  language. Andrew's voice message of 2026-09-28 switched from Ukrainian to
  English to Spanish at pauses of a third to half a second, and came back as
  160 bytes of Russian with the English sentence lost. These recordings are
  tone and silence at known times, so every cut lands at a known byte.
  """
  use ExUnit.Case, async: true
  alias Ryker.Transcription.Parts

  # 16 kHz mono 16-bit: 32,000 bytes a second, 640 bytes a 20 ms frame.
  @second 32_000

  test "a recording is cut in the middle of each pause, and every byte is in one part" do
    pcm = speech(3.0) <> silence(0.6) <> speech(3.0) <> silence(0.5) <> speech(2.5)

    # The first pause is 3.0-3.6 s, the second 6.6-7.1 s: cut at 3.3 s and
    # 6.85 s, on a 20 ms frame.
    assert Parts.split(pcm) == [
             {0, at(3.3)},
             {at(3.3), at(6.84) - at(3.3)},
             {at(6.84), byte_size(pcm) - at(6.84)}
           ]
  end

  test "a word or two after a pause stays with the part before it" do
    pcm = speech(3.0) <> silence(0.5) <> speech(1.0)
    assert Parts.split(pcm) == [{0, byte_size(pcm)}]
  end

  test "a word or two before the first pause joins the part after it" do
    pcm = speech(1.0) <> silence(0.5) <> speech(3.0) <> silence(0.5) <> speech(3.0)

    # Pauses at 1.0-1.5 s and 4.5-5.0 s: the first second joins the next part,
    # which ends in the middle of the second pause.
    assert [{0, first}, {second_start, second}] = Parts.split(pcm)
    assert first == second_start
    assert first + second == byte_size(pcm)
    assert first == at(4.74)
  end

  test "a pause shorter than 0.3 s is not a place to cut" do
    pcm = speech(3.0) <> silence(0.2) <> speech(3.0)
    assert Parts.split(pcm) == [{0, byte_size(pcm)}]
  end

  test "speech without a pause, silence alone, and nothing at all are one part or none" do
    assert Parts.split(speech(10.0)) == [{0, 10 * @second}]
    assert Parts.split(silence(10.0)) == [{0, 10 * @second}]
    assert Parts.split(<<>>) == []
    # A trailing half sample is not audio.
    assert Parts.split(speech(3.0) <> <<1>>) == [{0, 3 * @second}]
  end

  # whisper reads each part as a whole 30-second window, so a long message
  # with a pause every few seconds would take longer than its deadline.
  test "a long recording is at most twelve parts, still covering every byte" do
    pcm = Enum.map_join(1..30, fn _index -> speech(2.5) <> silence(0.5) end)
    parts = Parts.split(pcm)

    assert length(parts) == 12
    assert contiguous?(parts, byte_size(pcm))
  end

  test "a part is written as a WAV file whisper reads, and its samples read back" do
    pcm = speech(0.5)
    wav = Parts.wav(pcm)

    assert <<"RIFF", size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
             16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data",
             data_size::little-32, ^pcm::binary>> = wav

    assert size == byte_size(wav) - 8
    assert data_size == byte_size(pcm)
    assert Parts.samples(wav) == {:ok, pcm}
  end

  # ffmpeg writes a LIST chunk before the samples; a 44-byte header read them
  # as sound.
  test "the samples are the data chunk, after any chunk ffmpeg writes before it" do
    pcm = speech(0.1)
    list = "INFOISFT" <> <<14::little-32>> <> "Lavf63.1.102" <> <<0, 0>>

    wav =
      "RIFF" <>
        <<4 + 24 + 8 + byte_size(list) + 8 + byte_size(pcm)::little-32>> <>
        "WAVE" <>
        "fmt " <>
        <<16::little-32, 1::little-16, 1::little-16, 16_000::little-32, 32_000::little-32,
          2::little-16, 16::little-16>> <>
        "LIST" <>
        <<byte_size(list)::little-32>> <> list <> "data" <> <<byte_size(pcm)::little-32>> <> pcm

    assert Parts.samples(wav) == {:ok, pcm}
    assert Parts.samples("not a wav") == :error
  end

  # A square wave at 200 Hz, a quarter of full scale, stands for speech.
  defp speech(seconds) do
    samples = round(seconds * 16_000)
    for index <- 0..(samples - 1), into: <<>>, do: <<square(index)::little-signed-16>>
  end

  defp square(index), do: if(rem(div(index, 40), 2) == 0, do: 8_000, else: -8_000)

  defp silence(seconds), do: :binary.copy(<<0, 0>>, round(seconds * 16_000))

  defp at(seconds), do: round(seconds * 50) * 640

  defp contiguous?(parts, size) do
    {end_at, ordered} =
      Enum.reduce(parts, {0, true}, fn {offset, length}, {expected, ordered} ->
        {offset + length, ordered and offset == expected and length > 0}
      end)

    ordered and end_at == size
  end
end
