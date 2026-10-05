defmodule Ryker.Transcription.LocalTest do
  # Stand-in ffmpeg and whisper programs, written per test, take the place of
  # the real ones: every bound is checked without running a speech model.
  use ExUnit.Case, async: true

  alias Ryker.Transcription.{Local, Parts}

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ryker-transcription-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{tmp_dir: dir}
  end

  # One second of 16 kHz mono 16-bit PCM, and the WAV header before it.
  @second 32_000
  @header 44

  test "a recording becomes one line of words and leaves no files behind", %{tmp_dir: dir} do
    options =
      options(dir,
        ffmpeg: converter(dir, 2 * @second),
        whisper: recognizer(dir, " Please audit the checkout service.\n[BLANK_AUDIO]\n")
      )

    assert Local.transcribe("m4a bytes", options) ==
             {:ok, "Please audit the checkout service."}

    assert File.ls!(work_dir(dir)) == []
  end

  # Andrew's voice message of 2026-09-28 switched from Ukrainian to English
  # to Spanish and came back as 160 bytes of Russian: whisper hears a
  # recording's language once, from its first seconds, and the English
  # sentence in the middle was lost. Cut at its pauses and read part by part,
  # the same recording gave the sentence word for word. The words below are
  # what whisper's base model said for each part of that recording.
  test "a message that switches language is heard part by part, each in its own language",
       %{tmp_dir: dir} do
    three_parts = speech(3.0) <> silence(0.6) <> speech(3.0) <> silence(0.5) <> speech(2.5)

    whisper =
      program(dir, "whisper", """
      printf '%s\n' "$@" >> '#{Path.join(dir, "whisper-args")}'
      for arg; do
        case "$arg" in
          *part-000.wav) printf '%s' ' Toman, Toman, Toman!' > "$arg.txt" ;;
          *part-001.wav) printf '%s' ' Can you understand multiple languages in the same message?' > "$arg.txt" ;;
          *part-002.wav) printf '%s' ' Hello, how are you?' > "$arg.txt" ;;
        esac
      done
      """)

    options = options(dir, ffmpeg: converter(dir, three_parts), whisper: whisper)

    assert Local.transcribe("m4a bytes", options) ==
             {:ok,
              "Toman, Toman, Toman! Can you understand multiple languages in the same message? " <>
                "Hello, how are you?"}

    # One run over the three parts, each left to find its own language.
    arguments = dir |> Path.join("whisper-args") |> File.read!() |> String.split("\n", trim: true)
    assert ["-l", "auto"] in Enum.chunk_every(arguments, 2, 1)

    assert arguments |> Enum.filter(&String.ends_with?(&1, ".wav")) |> Enum.map(&Path.basename/1) ==
             ["part-000.wav", "part-001.wav", "part-002.wav"]

    assert File.ls!(work_dir(dir)) == []
  end

  # A voice message longer than Ryker transcribes is refused as too long, the
  # reason the person hears, not transcribed to its first minutes as if that
  # were all it said; whisper, the slow part, never starts.
  test "a recording past the time limit is refused before whisper runs", %{tmp_dir: dir} do
    options =
      options(dir,
        ffmpeg: converter(dir, 3 * @second),
        maximum_seconds: 2,
        whisper: recognizer(dir, "never read")
      )

    assert Local.transcribe("m4a bytes", options) == {:error, :too_long}
    refute File.exists?(Path.join(dir, "whisper-ran"))
    assert File.ls!(work_dir(dir)) == []
  end

  test "a recording past the size limit is refused before anything runs", %{tmp_dir: dir} do
    options =
      options(dir,
        ffmpeg: converter(dir, @second),
        maximum_bytes: 10,
        whisper: recognizer(dir, "never read")
      )

    assert Local.transcribe("eleven byte", options) == {:error, :too_large}
    refute File.exists?(Path.join(dir, "ffmpeg-ran"))
    assert File.ls!(work_dir(dir)) == []
  end

  # Slack's gateway transcribes before it acknowledges the event and handles
  # nothing else meanwhile, so a transcription with no deadline would hold
  # every Slack message behind it. Closing the port does not stop a program
  # that is busy computing: it has to be killed, and only by its own id.
  test "a transcription past its deadline is killed by its exact process and leaves no files behind",
       %{tmp_dir: dir} do
    pid_file = Path.join(dir, "ffmpeg.pid")

    ffmpeg =
      program(dir, "ffmpeg", """
      echo $$ > '#{pid_file}'
      exec sleep 30
      """)

    options =
      options(dir, ffmpeg: ffmpeg, timeout_ms: 1_000, whisper: recognizer(dir, "never read"))

    started = System.monotonic_time(:millisecond)

    assert Local.transcribe("m4a bytes", options) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - started < 10_000

    refute pid_file |> File.read!() |> String.trim() |> alive?()
    refute File.exists?(Path.join(dir, "whisper-ran"))
    assert File.ls!(work_dir(dir)) == []
    refute_received {_port, {:exit_status, _status}}
  end

  # ffmpeg reads uploads from anyone in a channel, and it and whisper ran with
  # Ryker's whole environment: the credential key, the state-tools signing
  # token and the database URL (2026-10-04 review). They get what a program
  # needs to run and nothing else.
  test "the programs that read a recording never see Ryker's keys", %{tmp_dir: dir} do
    key = "RYKER_TRANSCRIPTION_TEST_KEY_#{System.unique_integer([:positive])}"
    System.put_env(key, "master-key-value")
    on_exit(fn -> System.delete_env(key) end)
    environment = Path.join(dir, "ffmpeg-environment")

    ffmpeg =
      program(dir, "ffmpeg", """
      env > '#{environment}'
      exit 1
      """)

    options = options(dir, ffmpeg: ffmpeg, whisper: recognizer(dir, "never read"))
    assert {:error, _reason} = Local.transcribe("m4a bytes", options)

    # Messages only: a failure must not print the environment it read.
    names =
      environment |> File.read!() |> String.split("\n") |> Enum.map(&hd(String.split(&1, "=")))

    refute key in names, "ffmpeg saw #{key}"
    assert Enum.filter(names, &String.starts_with?(&1, "RYKER_")) == []
    assert "PATH" in names, "ffmpeg ran without PATH"
  end

  test "a missing program or model is a transcription Ryker could not make", %{tmp_dir: dir} do
    options = options(dir, ffmpeg: converter(dir, @second), whisper: Path.join(dir, "missing"))

    assert Local.transcribe("m4a bytes", options) == {:error, :unavailable}
    assert Local.transcribe("", options(dir, [])) == {:error, :failed}
  end

  defp options(dir, overrides) do
    model = Path.join(dir, "model.bin")
    File.write!(model, "model")
    File.mkdir_p!(work_dir(dir))

    Keyword.merge([model: model, threads: 1, tmp_dir: work_dir(dir)], overrides)
  end

  defp work_dir(dir), do: Path.join(dir, "work")

  # Writes a WAV where ffmpeg's last argument says: silence of the given
  # length, or the given samples.
  defp converter(dir, audio_bytes) when is_integer(audio_bytes),
    do: converter(dir, :binary.copy(<<0>>, audio_bytes))

  defp converter(dir, samples) when is_binary(samples) do
    prepared = Path.join(dir, "prepared.wav")
    File.write!(prepared, Parts.wav(samples))
    @header = byte_size(Parts.wav(<<>>))

    program(dir, "ffmpeg", """
    touch '#{Path.join(dir, "ffmpeg-ran")}'
    for last; do :; done
    cp '#{prepared}' "$last"
    """)
  end

  # Writes the given text beside each part whisper is given.
  defp recognizer(dir, text) do
    program(dir, "whisper", """
    touch '#{Path.join(dir, "whisper-ran")}'
    for arg; do
      case "$arg" in
        *.wav) printf '%s' '#{text}' > "$arg.txt" ;;
      esac
    done
    """)
  end

  # A square wave a quarter of full scale stands for speech.
  defp speech(seconds) do
    for index <- 0..(round(seconds * 16_000) - 1),
        into: <<>>,
        do: <<if(rem(div(index, 40), 2) == 0, do: 8_000, else: -8_000)::little-signed-16>>
  end

  defp silence(seconds), do: :binary.copy(<<0, 0>>, round(seconds * 16_000))

  defp program(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # A killed program may be reaped a moment after it dies.
  defp alive?(os_pid, checks \\ 20) do
    {_output, status} = System.cmd("sh", ["-c", "kill -0 #{os_pid} 2>/dev/null"])

    cond do
      status != 0 -> false
      checks == 0 -> true
      true -> Process.sleep(50) == :ok and alive?(os_pid, checks - 1)
    end
  end
end
