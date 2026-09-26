defmodule Ryker.Webhooks.Presets do
  @moduledoc """
  The supported webhook source shapes, with a recorded sample of each.

  A preset is a starting point, not an authority: it fills in the adapter,
  the authentication method a provider actually supports and the grouping that
  provider's payloads need. Destination, context and credential reference stay
  explicit choices, because those are the fields that decide where an event can
  reach and what it may run as.

  The samples exist so a mapping can be checked against a real payload shape
  before an incident depends on it. They are the payloads the transform tests
  exercise, trimmed to one event. Each preset's title and description are
  what the webhook source form offers it as, in the sender's words.
  """

  @grafana_sample """
  {
    "status": "firing",
    "groupKey": "{}:{cluster=\\"va1\\",service=\\"api\\"}",
    "externalURL": "https://grafana.example/alerting/list",
    "commonLabels": {"cluster": "va1", "service": "api", "severity": "critical"},
    "commonAnnotations": {"description": "shared description"},
    "alerts": [
      {
        "status": "firing",
        "labels": {"alertname": "HighErrors"},
        "annotations": {"summary": "API error rate"},
        "startsAt": "2026-09-04T07:55:00Z",
        "fingerprint": "abc",
        "panelURL": "https://grafana.example/panel/1"
      }
    ]
  }
  """

  @universal_sample """
  {
    "title": "Checkout latency above target",
    "status": "firing",
    "severity": "critical",
    "summary": "p99 latency 2.4s over 5 minutes",
    "source_url": "https://status.example/incidents/1"
  }
  """

  @mapped_sample """
  {
    "id": "evt-4417",
    "state": "open",
    "subject": "Disk almost full on db-1",
    "details": {"severity": "warning", "url": "https://ops.example/alerts/4417"},
    "labels": {"service": "database"}
  }
  """

  @presets [
    %{
      key: :universal,
      adapter_kind: :universal,
      auth_kind: :hmac_sha256,
      group_by_labels: [],
      title: "Ryker's own format",
      description:
        "From a system you control. It names each event in Ryker's headers, so the body can " <>
          "be any JSON, and Ryker keeps all of it.",
      sample: @universal_sample
    },
    %{
      key: :grafana,
      adapter_kind: :grafana,
      auth_kind: :bearer,
      group_by_labels: ["cluster", "service"],
      title: "Grafana alerts",
      description:
        "From a Grafana contact point. Each alert in a delivery becomes its own event, and " <>
          "alerts with the same group-by labels count as one situation.",
      sample: @grafana_sample
    },
    %{
      key: :mapped_json,
      adapter_kind: :mapped_json,
      auth_kind: :hmac_sha256,
      group_by_labels: [],
      title: "Other JSON",
      description:
        "From any other sender whose format you cannot change. You say where its JSON keeps " <>
          "each event's ID, status and title.",
      sample: @mapped_sample
    }
  ]

  @spec all() :: [map()]
  def all, do: @presets

  @spec fetch(atom() | String.t()) :: {:ok, map()} | :error
  def fetch(key) when is_atom(key) do
    case Enum.find(@presets, &(&1.key == key)) do
      nil -> :error
      preset -> {:ok, preset}
    end
  end

  def fetch(key) when is_binary(key) do
    case Enum.find(@presets, &(Atom.to_string(&1.key) == key)) do
      nil -> :error
      preset -> {:ok, preset}
    end
  end

  @doc "The recorded sample payload for one adapter kind."
  @spec sample(atom() | String.t()) :: String.t()
  def sample(key) do
    case fetch(key) do
      {:ok, preset} -> String.trim(preset.sample)
      :error -> ""
    end
  end
end
