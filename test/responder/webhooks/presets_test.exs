defmodule Responder.Webhooks.PresetsTest do
  # A preset is what an operator starts from when they connect a new alert
  # source. It must fill in only the provider's own shape, and its recorded
  # sample must still be one the transforms accept: a stale sample turns "Check
  # a payload" into a failure the operator reads as their own mistake.
  use ExUnit.Case, async: true

  alias Responder.Settings.WebhookSource
  alias Responder.Webhooks.{Presets, Preview}

  @mapping %{
    event_id: "id",
    severity: "details.severity",
    source_url: "details.url",
    status: "state",
    title: "subject"
  }

  test "every preset's recorded sample is still one its own adapter accepts" do
    for preset <- Presets.all() do
      body = Presets.sample(preset.key)
      assert {:ok, _payload} = Jason.decode(body)

      assert {:ok, [_first | _rest] = mapped} = Preview.check(source(preset), body),
             "the #{preset.key} sample no longer maps through the #{preset.adapter_kind} adapter"

      assert Enum.all?(mapped, &is_map/1)
    end
  end

  test "the grafana sample carries the whole group its preset promises to correlate" do
    # The preset says one delivery carries a group of alerts correlated by these
    # labels. A sample without them would prove nothing about that claim.
    {:ok, preset} = Presets.fetch(:grafana)
    assert preset.group_by_labels == ["cluster", "service"]

    payload = Jason.decode!(Presets.sample(:grafana))
    assert Map.keys(payload["commonLabels"]) -- preset.group_by_labels == ["severity"]
    assert payload["alerts"] != []
  end

  test "a preset fixes the provider's shape and never where an event may reach" do
    # Destination, context and credential decide what an inbound event can run
    # as. Prefilling them from a provider list is how a source ends up pointed
    # somewhere nobody chose.
    for preset <- Presets.all() do
      assert preset.adapter_kind in [:universal, :grafana, :mapped_json]
      assert preset.auth_kind in [:bearer, :hmac_sha256]
      assert is_list(preset.group_by_labels)
      assert preset.title != "" and preset.description != ""

      assert Map.keys(preset) |> Enum.sort() == [
               :adapter_kind,
               :auth_kind,
               :description,
               :group_by_labels,
               :key,
               :sample,
               :title
             ]
    end
  end

  test "the adapter the form posts resolves to the same preset as the atom it names" do
    for preset <- Presets.all() do
      assert Presets.fetch(preset.key) == {:ok, preset}
      assert Presets.fetch(Atom.to_string(preset.key)) == {:ok, preset}
      assert Presets.sample(Atom.to_string(preset.key)) == Presets.sample(preset.key)
    end

    # Every saved adapter kind has a preset, so the editor can always offer one.
    assert Enum.sort(Enum.map(Presets.all(), & &1.adapter_kind)) ==
             Enum.sort(Ecto.Enum.values(WebhookSource, :adapter_kind))
  end

  test "an adapter with no preset yields no sample instead of failing the editor" do
    # "Load sample" runs on whatever adapter the selected source happens to
    # carry. Raising there would take the whole settings page down.
    assert Presets.fetch(:pagerduty) == :error
    assert Presets.fetch("pagerduty") == :error
    assert Presets.sample(:pagerduty) == ""
    assert Presets.sample("pagerduty") == ""
  end

  defp source(preset) do
    %WebhookSource{
      name: "alerts",
      enabled: true,
      adapter_kind: preset.adapter_kind,
      auth_kind: preset.auth_kind,
      secret_name: "ALERTMANAGER_WEBHOOK_SECRET",
      destination_transport: "control_plane",
      destination_conversation_ref: "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44",
      destination_thread_ref: "control-plane:lab:6f1a0f38-0b74-4f77-9f20-7a0c1e2d3b44",
      context_ref: "responder",
      group_by_labels: preset.group_by_labels,
      mapping: mapping(preset.adapter_kind)
    }
  end

  # The custom preset deliberately ships no mapping: naming the paths is the
  # operator's job, and this is the mapping the sample was recorded for.
  defp mapping(:mapped_json),
    do: Map.new(@mapping, fn {field, path} -> {to_string(field), path} end)

  defp mapping(_preset_kind), do: nil
end
