defmodule Ryker.ControlPlane.CandidateResponseViewTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{InspectionRedactor, RequestPage}

  @fixture "test/ryker/work/fixtures/airflow_candidate_responses.json"

  test "each validation attempt retains its own collapsed response when the next candidate arrives" do
    # The real Airflow trial replaced a 518-byte first candidate and retained
    # only the latest of three attempts. Cleanup made that first response lost.
    # These two independently harvested responses compose a host-only sequence;
    # they do not reconstruct the trial's missing first response.
    [first, second] = responses()
    history = [check(1, first), check(2, second), check(3, second)]

    section = %{
      id: "validation",
      title: "Response checks",
      artifact: InspectionRedactor.artifact(%{"history" => history, "candidate_attempt" => 3}),
      responses: %{1 => first, 2 => second, 3 => second}
    }

    html = render_component(&RequestPage.artifact/1, section: section, prefix: "recorded")
    document = LazyHTML.from_document(html)
    attempts = LazyHTML.query(document, ".validation-attempt")

    assert Enum.count(attempts) == 3

    assert LazyHTML.query(document, ".validation-attempt > .case-card-heading") |> Enum.count() ==
             3

    for {attempt, response} <- [{1, first}, {2, second}, {3, second}] do
      card = Enum.at(attempts, attempt - 1)
      assert LazyHTML.query(card, ".candidate-response pre") |> LazyHTML.text() == response.text
      assert Enum.empty?(LazyHTML.query(card, ".candidate-response[open]"))

      assert LazyHTML.query(card, ".candidate-response") |> LazyHTML.attribute("id") ==
               ["recorded-response-#{attempt}"]

      disclosure = LazyHTML.query(card, ".candidate-response .ui-disclosure")
      assert LazyHTML.query(disclosure, "summary") |> LazyHTML.text() =~ "Raw response"
      assert LazyHTML.query(disclosure, "summary") |> LazyHTML.text() =~ "JSON"
    end

    assert Enum.empty?(LazyHTML.query(document, ".candidate-response a"))
    refute html =~ "Response body not retained for this attempt"
    refute html =~ "Response sent"
  end

  test "expired or mismatched attempt bodies never borrow the latest response" do
    [first, second] = responses()

    for {response, expected} <- [
          {InspectionRedactor.artifact(nil, expired: true), "Response body expired"},
          {second, "Response body not retained"}
        ] do
      section = %{
        id: "validation",
        title: "Response checks",
        artifact: InspectionRedactor.artifact(%{"history" => [check(1, first)]}),
        responses: %{1 => response}
      }

      html = render_component(&RequestPage.artifact/1, section: section, prefix: "unavailable")
      assert html =~ expected
      refute html =~ "candidate-response"
      refute html =~ "Verification remains inconclusive"
    end
  end

  test "a redacted or truncated attempt remains labeled and never exposes original bytes" do
    [first, _second] = responses()

    # Display fault injection, not an invented model answer. The original
    # candidate identity remains separate from the sanitized preview text.
    displayed = %{
      first
      | text: "[redacted]\n[display truncated]",
        redacted: true,
        truncated: true
    }

    section = %{
      id: "validation",
      title: "Response checks",
      artifact: InspectionRedactor.artifact(%{"history" => [check(1, first)]}),
      responses: %{1 => displayed}
    }

    html = render_component(&RequestPage.artifact/1, section: section, prefix: "safe")
    assert html =~ "Secrets redacted"
    assert html =~ "Display truncated"
    assert html =~ "[redacted]"
    refute html =~ "Verification is scheduled"
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

  defp check(attempt, response) do
    %{
      "candidate_attempt" => attempt,
      "candidate_sha256" => response.sha256,
      "response_bytes" => response.bytes,
      "verdict" => "reject",
      "violations" => [
        "Call validate_final with this exact candidate after completing all state-tool writes, then return the accepted candidate unchanged."
      ]
    }
  end
end
