defmodule Ryker.Knowledge.KnowledgeAnchorsTest do
  use ExUnit.Case, async: true
  alias Ryker.Knowledge.KnowledgeAnchors

  # Structural identity cases, not recorded model judgments. Lowercasing every
  # identity can merge different deployments/files; accepting invented anchors
  # lets one input attach itself to an unrelated subject.
  test "identity normalization preserves case except known platform URL equivalences" do
    assert KnowledgeAnchors.normalize("deploy:BuildA") == "deploy:BuildA"

    refute KnowledgeAnchors.normalize("deploy:BuildA") ==
             KnowledgeAnchors.normalize("deploy:builda")

    assert KnowledgeAnchors.normalize("https://github.com/Acme/Api/pull/42?tab=files#discussion") ==
             "https://github.com/acme/api/pull/42"

    assert KnowledgeAnchors.normalize("https://github.com/Acme/Api/blob/main/Config.ex") ==
             "https://github.com/Acme/Api/blob/main/Config.ex"

    assert KnowledgeAnchors.normalize(
             "https://acme.slack.com/archives/CABC/p1788632364248029?thread_ts=1"
           ) ==
             "https://acme.slack.com/archives/CABC/p1788632364248029"
  end

  test "proposed anchors must occur as whole identities in their sources or offered target" do
    assert KnowledgeAnchors.validate(["deploy:BuildA"], ["Failure in deploy:BuildA."], []) == :ok

    assert KnowledgeAnchors.validate(["deploy:BuildA"], ["Failure in deploy:BuildAB."], []) ==
             {:error, :knowledge_anchor_not_sourced}

    assert KnowledgeAnchors.validate(["deploy:builda"], ["Failure in deploy:BuildA."], []) ==
             {:error, :knowledge_anchor_not_sourced}

    assert KnowledgeAnchors.validate(["deploy:BuildA"], ["It recovered."], ["deploy:BuildA"]) ==
             :ok

    assert KnowledgeAnchors.validate(
             ["https://github.com/acme/api/pull/42"],
             ["See <https://github.com/Acme/Api/pull/42?tab=files|the PR>"],
             []
           ) == :ok

    assert KnowledgeAnchors.validate(["invented"], ["Nothing related"], []) ==
             {:error, :knowledge_anchor_not_sourced}
  end

  # Harvested from the live install, 2026-10-01 (learning batches af1a2541 and 8d0546d7): "Before a
  # change in AndrewDryga/test: the changelog there is HISTORY.md, …". The colon after the
  # repository is punctuation, yet it was read as the identity going on, as in "deploy:BuildA",
  # so every attempt that named the repository was refused: three starts each, and both
  # conversations stopped being learned until a person granted more.
  test "an identity followed by a colon and a space is the whole identity" do
    text =
      "Before a change in AndrewDryga/test: the changelog there is HISTORY.md, newest entry on top, and every entry starts with a date in brackets. Just confirm for now."

    assert KnowledgeAnchors.validate(["AndrewDryga/test", "HISTORY.md"], [text], []) == :ok

    assert KnowledgeAnchors.validate(["AndrewDryga/test"], ["Deploy AndrewDryga/test:"], []) ==
             :ok

    # A colon that joins more identity still does not end it.
    assert KnowledgeAnchors.validate(["deploy"], ["Failure in deploy:BuildA."], []) ==
             {:error, :knowledge_anchor_not_sourced}
  end

  test "automatic candidate identities are bounded and never generalize a URL path" do
    identities =
      KnowledgeAnchors.discover([
        "See https://github.com/Acme/Api/pull/42 and allocation 7abc3462-415e-4c6a-8688-c6a0778fe5bc."
      ])

    assert "https://github.com/acme/api/pull/42" in identities
    assert "7abc3462-415e-4c6a-8688-c6a0778fe5bc" in identities
    refute "https://github.com/acme/api" in identities

    assert length(
             KnowledgeAnchors.discover(for n <- 1..100, do: "https://github.com/a/b/pull/#{n}")
           ) <= 64
  end

  test "anchor validation uses the complete submitted source including structured URLs" do
    entry = %{
      content: %{
        "text" =>
          String.duplicate("boilerplate ", 100) <>
            " deployment:BuildA",
        "blocks" => [%{"url" => "https://github.com/Acme/Api/pull/42?tab=files"}]
      }
    }

    texts = KnowledgeAnchors.source_texts([entry])

    assert KnowledgeAnchors.validate(
             ["deployment:BuildA", "https://github.com/acme/api/pull/42"],
             texts,
             []
           ) == :ok
  end
end
