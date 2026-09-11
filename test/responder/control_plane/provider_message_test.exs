defmodule Responder.ControlPlane.ProviderMessageTest do
  @moduledoc """
  Provider-specific received-message cards.

  A Terraform run notification read as a flattened paragraph hides which run,
  in what state, from where. Recognition is a presentation projection over the
  retained content: it promotes a few labelled facts from shapes with a
  harvested example behind them and leaves every unknown format on the generic
  card. It proves a format, never a sender.
  """
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.ProviderMessage

  @terraform "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()

  test "a harvested HCP Terraform notification is recognized with its run, state and facts" do
    content = Map.take(@terraform, ["text", "attachments", "subtype", "bot_id"])
    assert %{provider: :terraform} = card = ProviderMessage.recognize("slack", content)

    assert card.name == "HCP Terraform"
    assert card.state == "Planning"
    assert card.tone == :planning
    assert card.subject == "Dryga/emisar"

    facts = Map.new(card.facts, &{&1.label, &1.value})
    assert facts["Branch"] == "main"
    assert facts["Commit"] == "3376639b89c540d3742f2b17900dbdd6403bfb4d"
    assert facts["Author"] == "AndrewDryga"
    assert facts["GitHub run"] == "34306095502"
    assert facts["Run"] == "run-k9CpPp3nWjQrkCMG"
    refute Map.has_key?(facts, "Description")

    assert Enum.map(card.links, & &1.label) == ["Open run", "Open workspace"]
    assert Enum.all?(card.links, &String.starts_with?(&1.href, "https://app.terraform.io/"))
  end

  test "an unfamiliar description is preserved rather than half-parsed" do
    content =
      update_in(@terraform, ["attachments"], fn [run | rest] ->
        [
          Map.put(run, "text", "Triggered from the CLI without a commit"),
          Map.put(hd(rest), "title", "Run Errored")
        ]
      end)

    card = ProviderMessage.recognize("slack", Map.take(content, ["attachments"]))
    facts = Map.new(card.facts, &{&1.label, &1.value})
    assert facts["Description"] == "Triggered from the CLI without a commit"
    refute Map.has_key?(facts, "Branch")
    assert card.state == "Errored"
    assert card.tone == :failure
  end

  test "a keyword is not a format: text mentioning Terraform stays generic" do
    assert ProviderMessage.recognize("slack", %{"text" => "Terraform plan looks fine"}) == nil

    assert ProviderMessage.recognize("slack", %{
             "attachments" => [
               %{
                 "footer" => "HCP Terraform",
                 "title_link" => "https://evil.example/app/x/runs/y",
                 "title" => "Run r"
               }
             ]
           }) == nil
  end

  test "a native Grafana alert promotes its title, status and labels" do
    payload = %{
      "adapter" => "grafana",
      "title" => "HAProxy backend down",
      "summary" => "backend api has no healthy servers",
      "status" => "firing",
      "severity" => "critical",
      "labels" => %{"service" => "api", "instance" => "hvn01:9101"},
      "annotations" => %{},
      "starts_at" => "2026-09-03T14:08:50Z",
      "ends_at" => nil,
      "source_url" => "https://grafana.example/alerting/grafana/abc/view"
    }

    assert %{provider: :grafana} =
             card = ProviderMessage.recognize("webhook", %{"payload" => payload})

    assert card.state == "Firing"
    assert card.tone == :firing
    assert card.subject == "HAProxy backend down"
    facts = Map.new(card.facts, &{&1.label, &1.value})
    assert facts["Service"] == "api"
    assert facts["Instance"] == "hvn01:9101"
    assert facts["Severity"] == "critical"
    assert facts["Started"] == "2026-09-03T14:08:50Z"
    refute Map.has_key?(facts, "Ended")
    assert [%{label: "Open alert"}] = card.links

    resolved =
      ProviderMessage.recognize("webhook", %{
        "payload" => %{payload | "status" => "resolved", "ends_at" => "2026-09-03T14:14:50Z"}
      })

    assert resolved.tone == :resolved
    assert Map.new(resolved.facts, &{&1.label, &1.value})["Ended"] == "2026-09-03T14:14:50Z"
  end

  test "links are only ever https to a real host" do
    content =
      update_in(@terraform, ["attachments"], fn [run | rest] ->
        [
          Map.put(run, "pretext", "Run notification for <javascript:alert(1)|Dryga/emisar>")
          | rest
        ]
      end)

    card = ProviderMessage.recognize("slack", Map.take(content, ["attachments"]))
    assert Enum.map(card.links, & &1.label) == ["Open run"]
  end
end
