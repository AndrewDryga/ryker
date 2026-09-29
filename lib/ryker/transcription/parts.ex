defmodule Ryker.Transcription.Parts do
  @moduledoc """
  Cuts a recording into the parts whisper transcribes one by one, at the
  pauses between them.

  whisper.cpp hears the language of a recording once, from its first
  seconds, and reads everything after in that language. A voice message that
  switches language came back as the first language's words, or none: Andrew's
  33-second message of 2026-09-28, Ukrainian, then English, then Spanish, was
  transcribed as 160 bytes of Russian, and the English sentence in the middle
  was lost. Each part is transcribed as its own recording, so each is heard in
  its own language (`Ryker.Transcription.Local`).

  A pause is at least 0.3 s quieter than the recording's own speech: the
  quietest tenth of it is its floor, the loudest tenth its speech, and a pause
  sits below 30% of the way from one to the other. The cut is in the middle
  of the pause. A recording with no clear pause is one part.

  A part shorter than 2 s joins the one before it (the first joins the next),
  since a language cannot be told from a word or two. whisper reads every part
  as a 30-second window whatever its length, about 1.4 s each with the base
  model on the Compose host, so a recording is at most 12 parts and the
  longest one still finishes inside its deadline: past that, the shortest part
  joins its shorter neighbour until 12 are left. The same samples always make
  the same parts.
  """

  # 16 kHz mono 16-bit PCM.
  @sample_rate 16_000
  @bytes_per_sample 2
  @frame_samples 320
  @frame_bytes @frame_samples * @bytes_per_sample
  @frames_per_second div(@sample_rate, @frame_samples)
  @pause_frames round(0.3 * @frames_per_second)
  @shortest_part_bytes 2 * @sample_rate * @bytes_per_sample
  @most_parts 12
  # Below this spread between speech and floor there is no pause to find.
  @least_contrast_db 10.0
  @threshold 0.3

  @type part :: {offset :: non_neg_integer(), length :: pos_integer()}

  @doc """
  The parts of `pcm` (16 kHz mono signed 16-bit little-endian samples) as
  byte offsets and lengths, in order, covering every byte.
  """
  @spec split(binary()) :: [part()]
  def split(pcm) when is_binary(pcm) do
    size = byte_size(pcm) - rem(byte_size(pcm), @bytes_per_sample)

    if size == 0 do
      []
    else
      pcm
      |> binary_part(0, size)
      |> cuts()
      |> parts(size)
      |> join_short()
      |> at_most(@most_parts)
    end
  end

  @doc """
  The samples of a WAV file: its data chunk. ffmpeg writes a LIST chunk of
  its own before the data, so the samples do not start at a fixed offset.
  """
  @spec samples(binary()) :: {:ok, binary()} | :error
  def samples(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>), do: data(chunks)
  def samples(_wav), do: :error

  defp data(<<"data", size::little-32, rest::binary>>),
    do: {:ok, binary_part(rest, 0, min(size, byte_size(rest)))}

  defp data(<<_id::binary-4, size::little-32, rest::binary>>) do
    # A chunk of odd size is followed by a pad byte.
    skip = size + rem(size, 2)

    if byte_size(rest) >= skip,
      do: data(binary_part(rest, skip, byte_size(rest) - skip)),
      else: :error
  end

  defp data(_chunks), do: :error

  @doc "A WAV file of `pcm` (16 kHz mono signed 16-bit), as whisper reads one."
  @spec wav(binary()) :: binary()
  def wav(pcm) when is_binary(pcm) do
    size = byte_size(pcm)

    <<"RIFF", 36 + size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      @sample_rate::little-32, @sample_rate * @bytes_per_sample::little-32,
      @bytes_per_sample::little-16, 16::little-16, "data", size::little-32, pcm::binary>>
  end

  # -- Pauses --------------------------------------------------------------------------

  # The byte offsets to cut at: the middle of each pause, on a sample.
  defp cuts(pcm) do
    levels = levels(pcm)

    case threshold(levels) do
      nil ->
        []

      threshold ->
        levels
        |> Enum.with_index()
        |> Enum.chunk_by(fn {level, _index} -> level < threshold end)
        |> Enum.filter(fn [{level, _index} | _rest] = run ->
          level < threshold and length(run) >= @pause_frames
        end)
        |> Enum.map(fn [{_level, first} | _rest] = run ->
          (first + div(length(run), 2)) * @frame_bytes
        end)
    end
  end

  # Each 20 ms frame's loudness in dB below full scale; a partial frame at
  # the end is left out.
  defp levels(pcm) do
    for <<frame::binary-size(@frame_bytes) <- pcm>>, do: level(frame)
  end

  defp level(frame) do
    sum = for <<sample::little-signed-16 <- frame>>, reduce: 0, do: (sum -> sum + sample * sample)
    rms = :math.sqrt(sum / @frame_samples)
    if rms < 1.0, do: -100.0, else: 20 * :math.log10(rms / 32_768)
  end

  defp threshold(levels) when length(levels) < 2 * @pause_frames, do: nil

  defp threshold(levels) do
    sorted = Enum.sort(levels)
    count = length(sorted)
    floor = Enum.at(sorted, div(count, 10))
    speech = Enum.at(sorted, div(count * 9, 10))

    if speech - floor >= @least_contrast_db, do: floor + @threshold * (speech - floor)
  end

  # -- Parts ---------------------------------------------------------------------------

  defp parts(cuts, size) do
    edges = [0 | Enum.filter(cuts, &(&1 > 0 and &1 < size))] ++ [size]

    edges
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] -> {from, to - from} end)
  end

  defp join_short([]), do: []
  defp join_short([only]), do: [only]

  defp join_short([{offset, length}, {_next, next_length} | rest])
       when length < @shortest_part_bytes,
       do: join_short([{offset, length + next_length} | rest])

  defp join_short(parts) do
    parts
    |> Enum.reduce([], fn
      {_offset, length}, [{previous, previous_length} | done]
      when length < @shortest_part_bytes ->
        [{previous, previous_length + length} | done]

      part, done ->
        [part | done]
    end)
    |> Enum.reverse()
  end

  defp at_most(parts, most) when length(parts) <= most, do: parts

  defp at_most(parts, most) do
    indexed = Enum.with_index(parts)

    {{_offset, _length}, shortest} =
      Enum.min_by(indexed, fn {{_offset, length}, _index} -> length end)

    neighbour = shorter_neighbour(parts, shortest)
    {first, second} = {min(shortest, neighbour), max(shortest, neighbour)}
    {offset, length} = Enum.at(parts, first)
    {_offset, next_length} = Enum.at(parts, second)

    parts
    |> List.replace_at(first, {offset, length + next_length})
    |> List.delete_at(second)
    |> at_most(most)
  end

  defp shorter_neighbour(parts, 0) when length(parts) > 1, do: 1
  defp shorter_neighbour(parts, index) when index == length(parts) - 1, do: index - 1

  defp shorter_neighbour(parts, index) do
    {_offset, before} = Enum.at(parts, index - 1)
    {_offset, after_it} = Enum.at(parts, index + 1)
    if before <= after_it, do: index - 1, else: index + 1
  end
end
