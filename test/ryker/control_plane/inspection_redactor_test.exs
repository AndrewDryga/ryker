defmodule Ryker.ControlPlane.InspectionRedactorTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.InspectionRedactor
  alias Ryker.ControlPlane.SlackMarkdown

  test "redacting a Slack alert URL preserves its complete readable label" do
    # The retained HAProxy alert lost 'Open' and displayed a long URL instead.
    [source | _] =
      File.read!("testdata/learning/retained-haproxy-lifecycle.json")
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    text = hd(source["content"]["attachments"])["text"]
    artifact = InspectionRedactor.artifact(text, secrets: [])
    html = SlackMarkdown.render(artifact.text) |> IO.iodata_to_binary()
    assert html =~ ">Open in Grafana</a>"
    assert html =~ ">Create silence</a>"
    refute artifact.text =~ "orgId=1"

    sanitized =
      InspectionRedactor.artifact(
        "<https://user:password@example.test/view?token=unpublished#secret|Open in Grafana>",
        secrets: []
      )

    assert sanitized.text == "<https://example.test/view|Open in Grafana>"
    refute sanitized.text =~ "unpublished"
    refute sanitized.text =~ "password"

    # A pipe in an ordinary URL is still query data, not a Slack label.
    for link <- [
          "https://example.test/view?token=first|second",
          "[Open](https://example.test/view?token=first|second)"
        ] do
      refute InspectionRedactor.artifact(link, secrets: []).text =~ "second"
    end
  end

  test "redacting URL credentials preserves the closing punctuation of Markdown links" do
    # The real OOM memory's ?orgId=1 link swallowed its closing parenthesis,
    # leaving an unclickable Markdown fragment in the operator preview.
    for query <- ["orgId=1", "token=unpublished-value", "X-Amz-Signature=opaque-value"] do
      artifact =
        InspectionRedactor.artifact("[Alert](https://example.test/view?#{query}).", secrets: [])

      assert artifact.text == "[Alert](https://example.test/view)."
      refute artifact.text =~ query
    end
  end

  test "preserving prompt bytes never restores a secret hidden by duplicate JSON keys" do
    # The exact-prompt viewer must inspect every occurrence, not just the decoder's last value.
    for text <- [
          ~s({"note":"safe","note":"Bearer hidden-value"}),
          ~s({"nested":{"note":"safe","no\\u0074e":"Bearer hidden-value"}}),
          ~s({"note":"safe","note":"Bearer hidd\\u0065n-value"})
        ] do
      artifact = InspectionRedactor.artifact(text, preserve_format: true, secrets: [])
      refute artifact.text =~ "hidden-value"
      refute artifact.text =~ "hidd\\u0065n"
      assert artifact.text =~ "safe"
    end
  end

  test "an incomplete angle link cannot expose a pipe-delimited URL credential" do
    for text <- [
          "<https://example.test/view?signature=first|opaque-unconfigured-secret",
          "<https://example.test/view?signature=first|opaque-unconfigured-secret\n>",
          "<https://example.test/view?signature=first|opaque-unconfigured-secret<broken>"
        ] do
      artifact = InspectionRedactor.artifact(text, secrets: [])
      refute artifact.text =~ "opaque-unconfigured-secret"
      refute artifact.text =~ "signature="
    end
  end

  test "provider-truncated structured evidence cannot bypass credential redaction" do
    for preview <- [
          ~s({"authorization":"Basic dXNlcjpmb3JlaWduLXNlY3JldA==","body":"),
          ~s({"credentials":{"user":"foreign-user","password":"foreign-value),
          "{\"file\":\"-----BEGIN PRIVATE KEY-----foreign-key"
        ] do
      artifact = InspectionRedactor.artifact(%{"truncated" => true, "preview" => preview})
      refute artifact.text =~ "dXNlcjpmb3JlaWduLXNlY3JldA"
      refute artifact.text =~ "foreign-"
    end

    for depth <- [31, 32, 33] do
      nested =
        Enum.reduce(1..depth, %{"truncated" => true, "preview" => "foreign-secret"}, fn _,
                                                                                        value ->
          %{"nested" => value}
        end)

      refute InspectionRedactor.artifact(nested).text =~ "foreign-secret"
    end
  end

  test "structured and embedded credentials are removed without hiding useful context" do
    input = %{
      "instructions" => "Inspect the deployment; retain input_tokens and the source URL.",
      "nested" => [%{"Authorization" => "Bearer secret-value", "input_tokens" => 42}],
      "message" =>
        "password=secret-value https://user:pass@example.com/path?token=secret-value#access_token=secret-value",
      "tool_result" => ~s({"api_key":"nested-secret","status":"ready"}),
      "code" => "<script>alert('x')</script>"
    }

    artifact = InspectionRedactor.artifact(input, secrets: ["secret-value"])
    assert artifact.state == :retained
    assert artifact.redacted
    refute artifact.text =~ "secret-value"
    refute artifact.text =~ "nested-secret"
    refute artifact.text =~ "user:pass"
    assert artifact.text =~ "input_tokens"
    assert artifact.text =~ "ready"
    assert artifact.text =~ "Inspect the deployment"
    assert artifact.text =~ "https://example.com/path"
    assert artifact.sha256 == Ryker.CanonicalJSON.digest(input)
  end

  test "a display bound never confuses omission or expiry with an empty request" do
    artifact = InspectionRedactor.artifact("hello " <> String.duplicate("é", 100), max_bytes: 32)
    assert artifact.truncated
    assert String.valid?(artifact.text)
    assert artifact.bytes == 206
    assert InspectionRedactor.artifact(nil).state == :not_recorded
    assert InspectionRedactor.artifact(nil, expired: true).state == :expired
    assert InspectionRedactor.artifact("").state == :retained
  end

  test "camel-case credentials and quoted assignments inside prose remain private" do
    document = %{
      "accessToken" => "camel-case-secret",
      "clientSecret" => "client-secret",
      "instructions" => ~s(Example: "api_key": "quoted-secret". Then inspect status.)
    }

    artifact = InspectionRedactor.artifact(document, secrets: [])
    refute artifact.text =~ "camel-case-secret"
    refute artifact.text =~ "client-secret"
    refute artifact.text =~ "quoted-secret"
    assert artifact.text =~ "inspect status"
  end

  test "configured secrets are found in keyword lists and client structs" do
    values =
      InspectionRedactor.secret_values(
        slack: [token: "keyword-token"],
        client: %URI{userinfo: "user:struct-secret"},
        secrets: %{"named" => "named-secret"},
        public: "do-not-hide"
      )

    assert "keyword-token" in values
    assert "user:struct-secret" in values
    assert "named-secret" in values
    refute "do-not-hide" in values
  end
end
