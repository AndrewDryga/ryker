defmodule Ryker.ControlPlane.CandidateResponseViewTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{EpisodeRequest, RequestPage}
  alias Ryker.InspectionRedactor

  @fixture "test/ryker/work/fixtures/airflow_candidate_responses.json"

  test "a redacted or truncated attempt never exposes original bytes and never reassures about secrets" do
    # Andrew, 2026-09-26, on a reply labelled "JSON · 467 bytes · Secrets
    # redacted": "there can't be secrets in that reply, i also do not want to
    # add disclaimers like 'Secrets redacted' anywhere". The redaction still
    # happens; only the reassurance is gone. A cut display still says so,
    # because that changes what the reader is looking at.
    [first, _second] = responses()

    # Display fault injection, not an invented model answer. The original
    # candidate identity remains separate from the sanitized preview text.
    displayed = %{
      first
      | text: "[redacted]\n[display truncated]",
        redacted: true,
        truncated: true
    }

    html =
      render_component(&RequestPage.candidate_response/1,
        response: displayed,
        attempt: 1,
        prefix: "safe"
      )

    assert html =~ "Display truncated"
    assert html =~ "[redacted]"
    refute html =~ ~r/secrets redacted/i
    refute html =~ "Verification is scheduled"
  end

  test "a reply with a configured secret in it shows the secret removed and no disclaimer" do
    # The recorded Airflow reply names revision 99183465; configured here as a
    # secret, it is exactly a secret that turned up in a model's answer.
    [%{text: body}, _second] = responses()
    redacted = InspectionRedactor.artifact(body, secrets: ["99183465"])
    assert redacted.redacted

    raw =
      render_component(&RequestPage.candidate_response/1,
        response: redacted,
        attempt: 1,
        prefix: "secret"
      )

    timeline =
      render_component(&EpisodeRequest.render/1,
        request: %{
          id: "request-secret-result",
          source_kind: :work,
          phase: :result,
          target: "codex:gpt-5.6-terra/medium@emisar",
          timing: [],
          href: "/timeline/example#request-secret",
          sections: [%{id: "candidate", title: "Response to validate", artifact: redacted}]
        }
      )

    for html <- [raw, timeline] do
      refute html =~ "99183465"
      assert html =~ "[redacted]"
      assert html =~ "JSON"
      refute html =~ ~r/secrets redacted/i
      refute html =~ ~r/· redacted/i
    end
  end

  # Andrew, 2026-09-27, of a checked answer's card that read "Sent as
  # written. Read the reply below ↓": drop it. The reply is on the same page,
  # a few cards down, so the checked answer's card keeps its check and its raw
  # response and says nothing about where the text went.
  test "an answer sent exactly as checked leaves its card without the text or a pointer to it" do
    [%{text: body} = response, _second] = responses()
    message = Jason.decode!(body)["message"]

    unsent =
      render_component(&RequestPage.candidate_response/1,
        response: response,
        attempt: 1,
        prefix: "turn-x"
      )
      |> LazyHTML.from_fragment()

    assert unsent |> LazyHTML.query(".ui-message-body") |> LazyHTML.text() =~
             String.slice(message, 0, 40)

    sent =
      render_component(&RequestPage.candidate_response/1,
        response: response,
        attempt: 1,
        prefix: "turn-x",
        sent: true
      )
      |> LazyHTML.from_fragment()

    assert sent |> LazyHTML.query(".ui-message") |> Enum.empty?()
    assert sent |> LazyHTML.query(".candidate-response-body a") |> Enum.empty?()
    refute LazyHTML.text(sent) =~ "Sent as written"
    assert sent |> LazyHTML.query(".ui-disclosure summary") |> LazyHTML.text() =~ "Raw response"
  end

  defp responses do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("responses")
    |> Enum.map(fn response ->
      artifact = InspectionRedactor.artifact(response["body"])
      assert artifact.sha256 == response["sha256"]
      assert artifact.bytes == response["bytes"]
      artifact
    end)
  end
end
