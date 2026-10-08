defmodule Ryker.Transcription.WorkerTest do
  @moduledoc """
  A Slack voice message is recorded with its transcript pending and
  acknowledged at once; this worker fills in the words afterwards, and routing
  waits for them.
  """
  use Ryker.DataCase, async: true
  alias Ryker.Admission
  alias Ryker.Admission.{Decision, Prompt}
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.SlackVoice
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.{AttachmentIngestor, Event}
  alias Ryker.TestTranscriber
  alias Ryker.Transcription.Worker

  # Admission builds its context in a repeatable-read snapshot.
  @moduletag isolation: "REPEATABLE READ"

  # A workspace of this suite's own, so its conversation locks and kept
  # recordings never meet another async suite's.
  @workspace_ref "T0VOICEWORK1"
  @identity %{bot_ref: "B-BOT", bot_user_ref: "UBOT", workspace_ref: @workspace_ref}

  defmodule CrashingTranscriber do
    @behaviour Ryker.Transcription

    @impl true
    def transcribe(_data, _options), do: raise("the speech model crashed")
  end

  # The words of a voice message arrive after it is recorded, and routing has
  # to read them: routing that read an unreadable file ignored Andrew's voice
  # message on 2026-09-27.
  test "routing waits for a voice message's transcript, then reads its words" do
    {entry, audio} = record_voice!("Ev-voice-words", "Please audit the checkout service")
    now = entry.inserted_at

    # Nothing earlier holds its conversation, yet routing cannot take it.
    assert Inbox.claim_next("routing:test", now, 60) == {:ok, nil}

    :ok = Inbox.subscribe_inputs()
    assert Worker.transcribe_next(transcriber: TestTranscriber) == {:ok, :transcribed}
    assert_received {:transcribed, ^audio}

    # The words wake routing, which takes the message at once.
    id = entry.id
    assert_received {:input_updated, ^id}

    assert {:ok, %{entry: claimed, lease_ref: lease_ref}} =
             Inbox.claim_next("routing:test", now, 60)

    assert claimed.id == id

    assert {:ok, context} =
             Admission.context(Inbox.ref(claimed),
               now: now,
               continuation_window: 30 * 60,
               history_window: 30 * 24 * 60 * 60,
               candidate_limit: 8,
               lease_ref: lease_ref
             )

    routing = context |> Prompt.build() |> get_in(["context", "input"]) |> CanonicalJSON.encode!()
    assert routing =~ "Please audit the checkout service"
    refute routing =~ "transcript_pending"

    # Routing's decision commits against the message the words were filled
    # into: its fingerprint did not change with them.
    assert {:ok, %{status: :applied}} =
             Admission.commit(context, ignore!(), "voice-words:ignore", lease_ref: lease_ref)
  end

  # A recording is bounded as before: one the transcriber could not read, or
  # one longer than Ryker transcribes, reaches routing saying so plainly.
  test "a voice message Ryker could not transcribe, or one too long, reaches routing saying so" do
    for {words, file_ref, ts, note} <- [
          {"FAIL", "F0VOICEFAIL1", "1790500001.000100",
           "a voice message Ryker could not transcribe"},
          {"TOO LONG", "F0VOICELONG1", "1790500002.000100",
           "a voice message longer than 5 minutes, the most Ryker transcribes"}
        ] do
      {entry, audio} =
        record_voice!("Ev-" <> file_ref, words,
          file: %{SlackVoice.file() | "id" => file_ref},
          ts: ts
        )

      assert Worker.transcribe_next(transcriber: TestTranscriber) == {:ok, :transcribed}
      assert_received {:transcribed, ^audio}

      assert {:ok, transcribed} = Inbox.fetch(Inbox.ref(entry))
      assert [%{"transcript_unavailable" => ^note} = file] = transcribed.content["files"]
      refute Map.has_key?(file, "transcript_pending")
      assert transcribed.awaiting_transcript_until == nil
    end
  end

  # Slack sends the same file again when it is shared again or edited, and a
  # transcript is kept beside its recording, so it is never transcribed twice.
  test "a recording already transcribed is read from what was kept, not transcribed again" do
    {_first, audio} = record_voice!("Ev-voice-first", "Restart the ingest workers")
    assert Worker.transcribe_next(transcriber: TestTranscriber) == {:ok, :transcribed}
    assert_received {:transcribed, ^audio}

    {again, _audio} =
      record_voice!("Ev-voice-shared-again", "Restart the ingest workers",
        ts: "1790500009.000100"
      )

    assert Worker.transcribe_next(transcriber: TestTranscriber) == {:ok, :transcribed}
    refute_received {:transcribed, _data}

    assert {:ok, transcribed} = Inbox.fetch(Inbox.ref(again))
    assert [%{"transcript" => "Restart the ingest workers"}] = transcribed.content["files"]
  end

  # One recording that breaks the transcriber must not leave its message
  # waiting, or take the worker down with it for every other voice message.
  test "a transcriber that crashes leaves a plain note instead of a stuck message" do
    {entry, _audio} = record_voice!("Ev-voice-crash", "never read")

    assert Worker.transcribe_next(transcriber: CrashingTranscriber) == {:ok, :transcribed}
    assert Worker.transcribe_next(transcriber: CrashingTranscriber) == :idle

    assert {:ok, transcribed} = Inbox.fetch(Inbox.ref(entry))

    assert [%{"transcript_unavailable" => "a voice message Ryker could not transcribe"}] =
             transcribed.content["files"]
  end

  # The message as the Slack gateway records it: Slack's event normalized, its
  # recording downloaded and kept, then recorded with the transcript pending.
  defp record_voice!(event_ref, words, options \\ []) do
    {file, options} = Keyword.pop(options, :file, SlackVoice.file())
    audio = TestTranscriber.recording(words)

    envelope =
      SlackVoice.envelope(
        event_ref,
        [file: file, workspace_ref: @workspace_ref, channel_ref: "D0VOICEWORK1"] ++ options
      )

    assert {:ok, normalized} = Event.from_socket(envelope, @identity)

    assert {:ok, %{input: input}} =
             AttachmentIngestor.ingest(
               normalized,
               SlackVoice.attachment_options({:ok, file, audio})
             )

    assert {:ok, %{entry: entry, status: :recorded}} =
             Inbox.record(input,
               one_input_per_revision: true,
               slack_audience: normalized.audience,
               slack_bot_user_ref: "UBOT"
             )

    {entry, audio}
  end

  defp ignore! do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "ignore",
               "episode_ref" => nil,
               "messages" => nil,
               "reactions" => nil,
               "relation" => "unrelated",
               "repository" => nil,
               "repository_source" => nil,
               "reason" => "Recorded model admission decision for this test.",
               "work_class" => nil
             })

    decision
  end
end
