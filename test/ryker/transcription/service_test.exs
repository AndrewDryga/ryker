defmodule Ryker.Transcription.ServiceTest do
  # Andrew, 2026-09-30: "we should make voice inputs work reliably". His voice
  # message of 2026-09-28 switched from Ukrainian to English to Spanish and
  # back, and Ryker's own small model wrote it as Russian and Portuguese.
  # whisper large-v3 on the Mac wrote every part in the language he spoke once
  # each part's language was chosen among the team's languages. A stand-in
  # server answers here with the language probabilities whisper gave for that
  # recording and each of its parts; a stand-in ffmpeg cuts a recording of six
  # spoken parts, as Ryker cuts his.
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Ryker.Transcription.{Parts, Service}

  @fixture "testdata/transcription/voice-2026-09-28-language-probabilities.json"
  @url "http://whisper.test:8178"
  @detect_url "http://whisper.test:8179"

  defmodule Fallback do
    def transcribe(data, options) do
      send(Keyword.fetch!(options, :test), {:fallback, data, Keyword.get(options, :timeout_ms)})
      {:ok, "words from Ryker's own model"}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "ryker-service-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "work"))
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "each part of a mixed-language message is written in the language spoken there",
       %{dir: dir, fixture: fixture} do
    {:ok, server} =
      Agent.start_link(fn ->
        %{detections: [fixture["whole"] | fixture["parts"]], written: []}
      end)

    request = fn url, fields, audio, _timeout_ms ->
      assert String.starts_with?(audio, "RIFF")
      fields = Map.new(fields)
      assert fields["response_format"] == "verbose_json"

      case url do
        @detect_url <> "/inference" ->
          assert fields["language"] == "auto"

          Agent.get_and_update(server, fn %{detections: [next | rest]} = state ->
            {{:ok, %{"language_probabilities" => next}}, %{state | detections: rest}}
          end)

        @url <> "/inference" ->
          Agent.get_and_update(server, fn state ->
            written = state.written ++ [fields["language"]]

            {{:ok, %{"text" => " part #{length(written)} (#{fields["language"]})\n"}},
             %{state | written: written}}
          end)
      end
    end

    assert Service.transcribe("m4a bytes", options(dir, request, six_parts())) ==
             {:ok, "part 1 (uk) part 2 (en) part 3 (es) part 4 (uk) part 5 (uk) part 6 (uk)"}

    assert Agent.get(server, & &1) == %{detections: [], written: fixture["expected"]}
    refute_received {:fallback, _data, _timeout_ms}
    assert File.ls!(Path.join(dir, "work")) == []
  end

  # A voice message is never lost to a stopped service: whisper on the Mac
  # may not be running, and then Ryker's own model reads the recording.
  test "a service that cannot be reached leaves the recording to Ryker's own model", %{dir: dir} do
    request = fn _url, _fields, _audio, _timeout_ms ->
      {:error, {:service, "could not be reached"}}
    end

    log =
      capture_log(fn ->
        assert Service.transcribe("m4a bytes", options(dir, request, six_parts())) ==
                 {:ok, "words from Ryker's own model"}
      end)

    assert log =~ "whisper service could not be reached"
    assert_received {:fallback, "m4a bytes", _timeout_ms}
  end

  # A Homebrew upgrade can change what whisper-server answers. Its voice
  # messages are still read, by Ryker's own model, and the log says why.
  test "a service that answers what Ryker cannot read leaves the recording to Ryker's own model",
       %{dir: dir} do
    request = fn _url, _fields, _audio, _timeout_ms -> {:ok, %{"unexpected" => true}} end

    log =
      capture_log(fn ->
        assert Service.transcribe("m4a bytes", options(dir, request, six_parts())) ==
                 {:ok, "words from Ryker's own model"}
      end)

    assert log =~ "whisper service answered without language probabilities"
    assert_received {:fallback, "m4a bytes", _timeout_ms}
  end

  # A recording has one budget, whichever model reads it: routing waits for
  # two recordings of it and no longer. Five minutes of speech took large-v3
  # 67 s on an M3 Pro, past the minute each recording once had, so the time a
  # stuck service spent is gone from what Ryker's own model gets.
  test "a stuck service leaves Ryker's own model only the rest of the recording's time",
       %{dir: dir} do
    request = fn _url, _fields, _audio, _timeout_ms ->
      # A stuck service spends part of the recording's time.
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
      Process.sleep(200)
      {:error, {:service, "did not answer in 30 s"}}
    end

    capture_log(fn ->
      assert Service.transcribe(
               "m4a bytes",
               dir |> options(request, six_parts()) |> Keyword.put(:timeout_ms, 5_000)
             ) == {:ok, "words from Ryker's own model"}
    end)

    assert_received {:fallback, "m4a bytes", timeout_ms}
    assert timeout_ms > 0 and timeout_ms <= 4_800
  end

  test "a recording whose time the service spent is not read again", %{dir: dir} do
    request = fn _url, _fields, _audio, _timeout_ms ->
      # A stuck service spends all of the recording's time.
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
      Process.sleep(600)
      {:error, {:service, "did not answer in 0 s"}}
    end

    capture_log(fn ->
      assert Service.transcribe(
               "m4a bytes",
               dir |> options(request, six_parts()) |> Keyword.put(:timeout_ms, 500)
             ) == {:error, :timeout}
    end)

    refute_received {:fallback, _data, _timeout_ms}
  end

  test "without whisper servers, Ryker's own model reads the recording in its time", %{dir: dir} do
    options =
      dir |> options(fn _url, _fields, _audio, _timeout -> flunk("no server") end, six_parts())

    assert Service.transcribe("m4a bytes", Keyword.merge(options, url: nil, detect_url: nil)) ==
             {:ok, "words from Ryker's own model"}

    assert_received {:fallback, "m4a bytes", timeout_ms}
    assert timeout_ms > 0 and timeout_ms <= Ryker.Transcription.recording_seconds() * 1_000
  end

  test "the request is one multipart form with the fields and the recording" do
    body =
      "b1"
      |> Service.multipart([{"language", "uk"}, {"response_format", "verbose_json"}], "RIFFdata")
      |> IO.iodata_to_binary()

    assert body ==
             ~s(--b1\r\nContent-Disposition: form-data; name="language"\r\n\r\nuk\r\n) <>
               ~s(--b1\r\nContent-Disposition: form-data; name="response_format"\r\n\r\n) <>
               ~s(verbose_json\r\n) <>
               ~s(--b1\r\nContent-Disposition: form-data; name="file"; filename="recording.wav"\r\n) <>
               ~s(Content-Type: audio/wav\r\n\r\nRIFFdata\r\n--b1--\r\n)
  end

  defp options(dir, request, samples) do
    [
      detect_url: @detect_url,
      fallback: Fallback,
      ffmpeg: converter(dir, samples),
      languages: ["uk", "en", "es"],
      request: request,
      test: self(),
      tmp_dir: Path.join(dir, "work"),
      url: @url
    ]
  end

  # Six parts of speech, each followed by a pause, as Ryker cut the recording.
  defp six_parts do
    Enum.map_join(1..6, &(speech(2.5) <> if(&1 < 6, do: silence(0.6), else: "")))
  end

  # Writes the given samples as the WAV ffmpeg's last argument names.
  defp converter(dir, samples) do
    prepared = Path.join(dir, "prepared.wav")
    File.write!(prepared, Parts.wav(samples))

    path = Path.join(dir, "ffmpeg")

    File.write!(path, """
    #!/bin/sh
    for last; do :; done
    cp '#{prepared}' "$last"
    """)

    File.chmod!(path, 0o755)
    path
  end

  # A square wave a quarter of full scale stands for speech.
  defp speech(seconds) do
    for index <- 0..(round(seconds * 16_000) - 1),
        into: <<>>,
        do: <<if(rem(div(index, 40), 2) == 0, do: 8_000, else: -8_000)::little-signed-16>>
  end

  defp silence(seconds), do: :binary.copy(<<0, 0>>, round(seconds * 16_000))
end
