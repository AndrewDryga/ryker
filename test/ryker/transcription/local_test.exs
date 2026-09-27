defmodule Ryker.Transcription.LocalTest do
  # Stand-in ffmpeg and whisper programs, written per test, take the place of
  # the real ones: every bound is checked without running a speech model.
  use ExUnit.Case, async: true

  alias Ryker.Transcription.Local

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

  # Writes a WAV of the given size where ffmpeg's last argument says.
  defp converter(dir, audio_bytes) do
    program(dir, "ffmpeg", """
    touch '#{Path.join(dir, "ffmpeg-ran")}'
    for last; do :; done
    head -c #{@header + audio_bytes} /dev/zero > "$last"
    """)
  end

  # Writes the given text where whisper's -of argument says.
  defp recognizer(dir, text) do
    program(dir, "whisper", """
    touch '#{Path.join(dir, "whisper-ran")}'
    while [ $# -gt 0 ]; do
      if [ "$1" = "-of" ]; then out="$2"; fi
      shift
    done
    printf '%s' '#{text}' > "$out.txt"
    """)
  end

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
