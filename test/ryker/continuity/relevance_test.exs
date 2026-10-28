defmodule Ryker.Continuity.RelevanceTest do
  use ExUnit.Case, async: true
  alias Ryker.Continuity.Relevance

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

    refute Relevance.related?(
             "A different heap allocation",
             Relevance.request(["Check heap exhaustion"])
           )
  end
end
