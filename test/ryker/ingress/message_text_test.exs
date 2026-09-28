defmodule Ryker.Ingress.MessageTextTest do
  use ExUnit.Case, async: true

  alias Ryker.Ingress.MessageText
  alias Ryker.Transcription

  # Messages Ryker recorded in #test on 2026-09-27, as it kept them.
  @retained "testdata/slack/retained-messages-2026-09-27.json"
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("messages")

  # Routing read the first message of Andrew's #test thread on 2026-09-28 as
  # "<@U0C1LCVNF52> check health of our infra\n check health of our infra".
  # Slack sends a person's message as its text and again as rich text blocks
  # with the same words, and both were read, so every earlier work a person
  # had mentioned Ryker in opened with its words twice. A block split mid-word
  # ("L", "ivebook is parked") added its pieces as lines of their own.
  test "a person's Slack message reads once, as its text, not again as its blocks" do
    assert MessageText.from(@retained["check_health"]["content"]) ==
             "<@U0C1LCVNF52> check health of our infra"

    livebook = @retained["livebook_parked"]["content"]
    assert MessageText.from(livebook) == livebook["text"]
  end

  # A voice message still waiting for its transcript has no words yet. It read
  # as every field Ryker keeps about the recording: "files[0].artifact_ref:
  # artifact:input:…", its bytes, digest, status, "slack_event_kind: message"
  # and an empty "text: ".
  test "a Slack message with no words of its own reads as what it carried, never as its structure" do
    voice = @retained["voice_no_tools_in_emisar"]["content"]

    assert MessageText.from(voice) ==
             "Just to confirm you don't see any tools in MSR itself right?"

    pending =
      Map.update!(voice, "files", fn files ->
        Enum.map(files, &Map.merge(Transcription.without_outcome(&1), Transcription.pending()))
      end)

    assert MessageText.from(pending) == "audio_message.m4a"

    assert MessageText.from(@retained["terraform_run_planning"]["content"]) ==
             """
             Run notification for <https://app.terraform.io/app/Dryga/emisar|Dryga/emisar>
             Run run-QJuP3FdKmSeFzoxM
             main 162c01814dcfe24dd1472ae107c437cd54de3e77 (@AndrewDryga, gh run 36348136738)
             HCP Terraform
             Run Planning\
             """
  end
end
