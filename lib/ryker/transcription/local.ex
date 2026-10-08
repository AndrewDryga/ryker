defmodule Ryker.Transcription.Local do
  @moduledoc """
  Transcribes a recording inside Ryker's container.

  ffmpeg turns any audio or video (m4a/mp4/aac, webm/ogg/opus, mp3, wav) into
  16 kHz mono WAV, which is cut at its pauses into parts
  (`Ryker.Transcription.Parts`), and whisper.cpp's CLI transcribes the parts
  in one run with a multilingual model, each in the language it hears there,
  so a message that switches language is read in each of them. The image
  carries both (see the Dockerfile's `whisper` stage); `RYKER_WHISPER_CLI`
  and `RYKER_WHISPER_MODEL` point elsewhere, for example at a larger model
  mounted into the container.

  Each call is bounded: the bytes before anything runs, the length ffmpeg
  measures after converting at most one second past the limit, and one
  deadline for both programs, after which the running one is killed by its
  exact process id. The working directory is removed however the call ends.
  """
  @behaviour Ryker.Transcription
  alias Ryker.ChildEnvironment
  alias Ryker.ChildProcess
  alias Ryker.Crypto
  alias Ryker.Transcription
  alias Ryker.Transcription.Parts

  @default_whisper "/opt/whisper/bin/whisper-cli"
  @default_model "/opt/whisper/ggml-base.bin"
  @timeout_ms 60_000
  # 16 kHz mono 16-bit PCM, after the WAV header.
  @wav_bytes_per_second 32_000
  @wav_header_bytes 44
  @maximum_output_bytes 64 * 1_024

  @impl true
  def transcribe(data, options \\ [])

  def transcribe(data, options) when is_binary(data) and data != "" and is_list(options) do
    settings = settings(options)

    cond do
      byte_size(data) > settings.maximum_bytes -> {:error, :too_large}
      not executables?(settings) -> {:error, :unavailable}
      true -> in_directory(settings.tmp_dir, &transcribe_in(data, &1, settings))
    end
  end

  def transcribe(_data, _options), do: {:error, :failed}

  @doc """
  The recording as 16 kHz mono WAV, cut at its pauses, handed to `function` as
  the whole file's path and its parts' paths, in a working directory removed
  afterwards. `Ryker.Transcription.Service` prepares recordings this way for
  whisper servers outside the container. What `function` returns is returned;
  a recording that cannot be prepared returns why.
  """
  @spec with_parts(binary(), keyword(), (String.t(), [String.t()] -> result)) ::
          result | {:error, Transcription.failure()}
        when result: term()
  def with_parts(data, options, function)
      when is_binary(data) and data != "" and is_list(options) and is_function(function, 2) do
    settings = settings(options)

    cond do
      byte_size(data) > settings.maximum_bytes ->
        {:error, :too_large}

      not ffmpeg?(settings) ->
        {:error, :unavailable}

      true ->
        in_directory(settings.tmp_dir, &prepared(data, &1, settings, function))
    end
  end

  def with_parts(_data, _options, _function), do: {:error, :failed}

  defp prepared(data, directory, settings, function) do
    deadline = System.monotonic_time(:millisecond) + settings.timeout_ms

    case prepare(data, directory, settings, deadline) do
      {:ok, wav, parts} -> function.(wav, parts)
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  defp transcribe_in(data, directory, settings) do
    deadline = System.monotonic_time(:millisecond) + settings.timeout_ms

    with {:ok, _wav, parts} <- prepare(data, directory, settings, deadline),
         :ok <- run(settings.whisper, recognize(parts, settings), deadline),
         {:ok, text} <- read_parts(parts) do
      case Transcription.words(text) do
        {:ok, words} -> {:ok, words}
        :error -> {:error, :no_speech}
      end
    else
      {:error, reason} -> {:error, failure(reason)}
    end
  end

  # Paths are a randomly named directory under the temporary root and fixed file names.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare(data, directory, settings, deadline) do
    recording = Path.join(directory, "recording")
    wav = Path.join(directory, "recording.wav")

    with :ok <- File.write(recording, data),
         :ok <- run(settings.ffmpeg, convert(recording, wav, settings), deadline),
         :ok <- within_length(wav, settings),
         {:ok, parts} <- write_parts(wav, directory) do
      {:ok, wav, parts}
    end
  end

  defp failure(reason) when reason in [:timeout, :too_long, :no_speech], do: reason
  defp failure(_reason), do: :failed

  # Each part of the recording as a WAV file of its own, in order.
  # Paths are a randomly named directory under the temporary root and fixed file names.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_parts(wav, directory) do
    with {:ok, bytes} <- File.read(wav),
         {:ok, pcm} <- samples(bytes) do
      case Parts.split(pcm) do
        [] -> {:error, :no_speech}
        parts -> parts |> Enum.with_index() |> write_each(pcm, directory, [])
      end
    end
  end

  defp write_each([], _pcm, _directory, written), do: {:ok, Enum.reverse(written)}

  # Paths are a randomly named directory under the temporary root and fixed file names.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_each([{{offset, length}, index} | rest], pcm, directory, written) do
    path = Path.join(directory, "part-#{String.pad_leading("#{index}", 3, "0")}.wav")

    case File.write(path, Parts.wav(binary_part(pcm, offset, length))) do
      :ok -> write_each(rest, pcm, directory, [path | written])
      {:error, reason} -> {:error, reason}
    end
  end

  defp samples(bytes) do
    case Parts.samples(bytes) do
      {:ok, pcm} -> {:ok, pcm}
      :error -> {:error, :unreadable_wav}
    end
  end

  # whisper writes each part's words beside it; a part it heard nothing in
  # may leave an empty file.
  # Paths are a randomly named directory under the temporary root and fixed file names.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_parts(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, texts} ->
      case File.read(part <> ".txt") do
        {:ok, text} -> {:cont, {:ok, [text | texts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  # ffmpeg reads the recording as whatever format its bytes claim, and some
  # formats (a playlist) name other sources it would then fetch; it may read
  # the local file and nothing else (2026-10-04 review). An ID3 header passes
  # `Ryker.Artifacts`' MP3 check whatever follows it, so ffmpeg may also use
  # only the demuxers of the containers Artifacts admits: MP4 and QuickTime,
  # WebM, Ogg, FLAC, WAV, MP3 and ADTS AAC.
  defp convert(recording, wav, settings) do
    ~w(-nostdin -hide_banner -loglevel error -protocol_whitelist file) ++
      ~w(-format_whitelist mov,matroska,ogg,flac,wav,mp3,aac -i) ++
      [recording, "-t", Integer.to_string(settings.maximum_seconds + 1)] ++
      ~w(-vn -ac 1 -ar 16000 -c:a pcm_s16le -f wav -y) ++ [wav]
  end

  # One run over every part: the model loads once, and each part is heard
  # in its own language (`-l auto` decides per file).
  defp recognize(parts, settings) do
    ["-m", settings.model, "-l", "auto", "-t", Integer.to_string(settings.threads)] ++
      ~w(-nt -np -otxt) ++ parts
  end

  # ffmpeg converted at most a second past the limit, so anything past the
  # limit and a half was cut: the recording is longer than Ryker transcribes.
  defp within_length(wav, settings) do
    case File.stat(wav) do
      {:ok, %{size: size}} ->
        seconds = (size - @wav_header_bytes) / @wav_bytes_per_second

        cond do
          seconds > settings.maximum_seconds + 0.5 -> {:error, :too_long}
          seconds < 0.1 -> {:error, :no_speech}
          true -> :ok
        end

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp run(executable, arguments, deadline) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: arguments,
        env: ChildEnvironment.port()
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    await(port, os_pid, deadline, 0)
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:spawn, Exception.message(error)}}
  end

  # Output is only read to keep the pipe from filling; it is never kept.
  defp await(port, os_pid, deadline, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} when bytes + byte_size(chunk) <= @maximum_output_bytes ->
        await(port, os_pid, deadline, bytes + byte_size(chunk))

      {^port, {:data, _chunk}} ->
        stop(port, os_pid)
        {:error, :output_too_large}

      {^port, {:exit_status, 0}} ->
        ChildProcess.flush(port)

      {^port, {:exit_status, status}} ->
        ChildProcess.flush(port)
        {:error, {:exit_status, status}}
    after
      remaining ->
        stop(port, os_pid)
        {:error, :timeout}
    end
  end

  # Closing the port does not stop a program that is busy computing, so the
  # program is killed by its exact process id, never by a name or a pattern.
  # The caller is a long-lived process, the transcription worker or Chat's
  # upload, so nothing the port sent is left in its mailbox.
  defp stop(port, os_pid) do
    ChildProcess.signal(os_pid, "KILL")
    ChildProcess.close(port)
  end

  # Paths are a randomly named directory under the temporary root and fixed file names.
  # sobelow_skip ["Traversal.FileModule"]
  defp in_directory(base, function) do
    suffix = Base.encode32(Crypto.random_bytes(10), case: :lower)
    directory = Path.join(base, "ryker-transcription-" <> suffix)

    case File.mkdir_p(directory) do
      :ok ->
        try do
          function.(directory)
        after
          File.rm_rf(directory)
        end

      {:error, _reason} ->
        {:error, :failed}
    end
  end

  defp executables?(settings) do
    ffmpeg?(settings) and File.regular?(settings.whisper) and File.regular?(settings.model)
  end

  defp ffmpeg?(settings), do: is_binary(settings.ffmpeg) and File.regular?(settings.ffmpeg)

  defp settings(options) do
    %{
      ffmpeg: Keyword.get_lazy(options, :ffmpeg, fn -> System.find_executable("ffmpeg") end),
      maximum_bytes: Keyword.get(options, :maximum_bytes, Transcription.maximum_bytes()),
      maximum_seconds: Keyword.get(options, :maximum_seconds, Transcription.maximum_seconds()),
      model:
        Keyword.get_lazy(options, :model, fn ->
          System.get_env("RYKER_WHISPER_MODEL", @default_model)
        end),
      threads: Keyword.get(options, :threads, min(System.schedulers_online(), 8)),
      timeout_ms: Keyword.get(options, :timeout_ms, @timeout_ms),
      tmp_dir: Keyword.get_lazy(options, :tmp_dir, &System.tmp_dir!/0),
      whisper:
        Keyword.get_lazy(options, :whisper, fn ->
          System.get_env("RYKER_WHISPER_CLI", @default_whisper)
        end)
    }
  end
end
