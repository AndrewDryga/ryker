defmodule Ryker.Ingress.RecallTextTest do
  use ExUnit.Case, async: true
  alias Ryker.Ingress.RecallText

  test "attachment and block text participate even when a top-level message is empty" do
    [source | _] =
      File.read!("testdata/learning/retained-haproxy-lifecycle.json")
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    text = RecallText.from(source["content"])
    assert text =~ "Host OOM kills"
    assert text =~ "website/haproxy-edge"
    refute text =~ "\"attachments\""

    assert RecallText.from(%{
             "text" => "",
             "blocks" => [%{"text" => %{"text" => "A retained decision"}}]
           }) == "A retained decision"
  end

  # Routing's earlier messages, digests and searches read a person's Slack
  # message this way. The first message of Andrew's #test thread went to
  # routing on 2026-09-28 as "<@U0C1LCVNF52> check health of our infra\n
  # check health of our infra": its text, then every "text" inside the rich
  # text blocks Slack sends beside it with the same words.
  test "a person's Slack message is searched and recalled once, as its text" do
    retained =
      "testdata/slack/retained-messages-2026-09-27.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("messages")

    assert RecallText.from(retained["check_health"]["content"]) ==
             "<@U0C1LCVNF52> check health of our infra"

    livebook = retained["livebook_parked"]["content"]
    assert RecallText.from(livebook) == livebook["text"]
  end

  # The replay over the Blitz alert history (2026-09-30, ID4): each part was cut at 512
  # characters, so a link crossing the cut became ".../alerting/sil", an identifier fourteen
  # unrelated alerts then shared. A part ends at its last whole word before the limit.
  test "a part cut at its limit ends at a whole word, never inside a link" do
    link = "https://grafana.example.com/alerting/silence/new?alertmanager=grafana"
    recalled = RecallText.from(%{"title" => String.duplicate("disk ", 100) <> link})

    refute recalled =~ "alerting"
    assert String.ends_with?(recalled, "disk")

    # Text with nowhere to cut, such as one long token, is still cut where the limit falls.
    assert String.length(RecallText.from(%{"title" => String.duplicate("x", 600)})) == 512
  end

  # The replay over the Blitz alert history (2026-09-30, ID7): 706 of 1,034 alerts carried their
  # link only on an attachment title or a button, mostly the Grafana rule page, and 85 of them
  # named nothing else; none of it was searched. This alert is one of them, its host renamed.
  test "a message's links on attachment titles, buttons and rich text are what it names" do
    rule =
      "https://grafana.example.net/alerting/grafana/va1-traefik-reload-frequency/view?orgId=1"

    incident = "https://uptime.example.com/team/t1/incidents/1009031809/api-unavailable"
    status = "https://status.example.com/incidents/42"

    content = %{
      "text" => "",
      "attachments" => [
        %{
          "color" => "daa038",
          "fallback" => "[VA1 FIRING:1] WARNING | Traefik config reload frequency high",
          "footer_icon" => "https://grafana.example.net/public/img/grafana_icon.svg",
          "text" =>
            "*FIRING - 1 alert*\n\n*Traefik completed more than 10 configuration reloads in 10 minutes*",
          "title" => "[VA1 FIRING:1] WARNING | Traefik config reload frequency high",
          "title_link" => rule
        }
      ],
      "blocks" => [
        %{"type" => "actions", "elements" => [%{"type" => "button", "url" => incident}]},
        %{
          "type" => "rich_text",
          "elements" => [
            %{
              "type" => "rich_text_section",
              "elements" => [%{"type" => "link", "url" => status, "text" => "status page"}]
            }
          ]
        }
      ]
    }

    assert RecallText.references(content) == %{links: [rule, incident, status], labels: []}
  end

  # Alertmanager's documented webhook body: an alert is known by its rule and its host, and
  # the same rule on the same host is the same incident, where the host alone is only related
  # (ID7 and ID9, 2026-09-30). Its words were searched; none of these were.
  test "an Alertmanager alert is known by its rule, its host, both together and its fingerprint" do
    graph = "https://prometheus.example.com/graph?g0.expr=cpu_usage%3E0.9"

    payload = %{
      "version" => "4",
      "status" => "firing",
      "receiver" => "ryker",
      "externalURL" => "https://alertmanager.example.com",
      "commonLabels" => %{"alertname" => "HighCPU", "instance" => "web-1:9100"},
      "alerts" => [
        %{
          "status" => "firing",
          "labels" => %{
            "alertname" => "HighCPU",
            "instance" => "web-1:9100",
            "severity" => "page"
          },
          "annotations" => %{"summary" => "CPU above 90% for 5 minutes"},
          "fingerprint" => "3f9a2b1c4d5e6f70",
          "generatorURL" => graph
        }
      ]
    }

    assert RecallText.references(payload) == %{
             links: [graph],
             labels: ["highcpu", "web-1:9100", "highcpu@web-1:9100", "3f9a2b1c4d5e6f70"]
           }

    # As a webhook source delivers it.
    assert RecallText.references(%{"event_type" => "alert", "payload" => payload}) ==
             RecallText.references(payload)

    assert RecallText.references(%{"text" => "plain words"}) == %{links: [], labels: []}
  end

  test "search extraction is bounded and never rewrites the original source" do
    content = %{
      "text" => String.duplicate("é", 20_000),
      "attachments" => [%{"title" => "Still searchable", "text" => "The useful attachment"}]
    }

    assert RecallText.from(content) =~ "Still searchable"
    assert RecallText.from(content) =~ "The useful attachment"
    assert String.valid?(RecallText.from(content))
    assert String.length(RecallText.from(content)) < 1000
    assert String.length(content["text"]) == 20_000
    assert RecallText.from(%{"state" => "resolved"}) == ~s({"state":"resolved"})
  end
end
