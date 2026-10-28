defmodule Ryker.Continuity.RelevanceTest do
  use ExUnit.Case, async: true
  alias Ryker.Continuity.Relevance
  alias Ryker.Ingress

  # Eight summaries filled a deployment briefing on 2026-10-28, including
  # unrelated runs whose only overlap was provider and lifecycle boilerplate.
  test "deployment boilerplate does not recall unrelated runs but the same revision still does" do
    fixture =
      Path.join(__DIR__, "fixtures/deployment_notification_recall.json")
      |> File.read!()
      |> Jason.decode!()

    source_text = Ingress.RecallText.from(fixture["content"])
    request = Relevance.request([source_text])

    text = fn state -> state |> Map.values() |> List.flatten() |> Enum.join("\n") end
    shared = fixture["shared_revision_state"]

    for state <- fixture["unrelated_states"],
        do: refute(Relevance.related?(text.(state), request), state["goal"])

    assert Relevance.rank(fixture["unrelated_states"] ++ [shared], request, text) == [shared]
    assert Relevance.related?("run-40db67e30e520eda has completed", request)

    subject = Relevance.request([source_text, "Website replica capacity"])
    assert Relevance.related?("Review website replica capacity", subject)
  end

  # A routine build briefing carried about 10,000 tokens of unrelated incidents.
  # These lexical boundary cases exercise selection, not fabricated model output.
  test "broad names and notification boilerplate cannot fill automatic recall" do
    request =
      Relevance.request(["Tenant production build succeeded https://example.test/build/123"])

    refute Relevance.related?("Tenant production database backup succeeded", request)
    refute Relevance.related?("https://example.test/incident/456", request)
    refute Relevance.related?("Host links recovered yesterday", request)
    assert Relevance.rank(["Tenant backup succeeded"], request, & &1) == []
    assert Relevance.rank(["A previous incident"], Relevance.request([]), & &1) == []

    refute Relevance.related?(
             "Please check disk space",
             Relevance.request(["Please check heap exhaustion"])
           )
  end

  test "exact lifecycle identifiers and substantive multiword subjects remain recallable" do
    assert Relevance.related?(
             "run-7abc42 finished",
             Relevance.request(["What happened to run-7abc42?"])
           )

    assert Relevance.related?(
             "V8 heap exhaustion remains unexplained",
             Relevance.request(["Check heap exhaustion"])
           )

    assert Relevance.related?(
             "Terraform state locking needs investigation",
             Relevance.request(["Explain Terraform state locking"])
           )

    refute Relevance.related?(
             "A different heap allocation",
             Relevance.request(["Check heap exhaustion"])
           )
  end
end
