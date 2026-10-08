defmodule Ryker.ControlPlane.SettingsRows do
  @moduledoc """
  How one saved row of a settings collection reads: a name, its state, what
  it does and one line of facts in the list, and on its own page the address
  a sender posts to, when it has one.
  """
  alias Ryker.ControlPlane.{Integrations, SettingsSections, ShortTime}
  alias Ryker.Slack
  alias Ryker.Work

  @type row :: %{
          icon: atom() | nil,
          name: String.t(),
          state: {atom(), String.t()} | nil,
          text: String.t() | nil,
          meta: [String.t() | {:strong, String.t()} | nil],
          address: String.t() | nil
        }

  @spec present(map(), struct(), map()) :: row()
  def present(%{key: :pricing}, rate, _view) do
    row(%{
      icon: :tag,
      name: model_name(rate.execution_target),
      meta:
        [provider(rate.execution_target)] ++
          prices(rate) ++ [effective(rate.effective_from), source(rate.provenance)]
    })
  end

  # A source the running configuration left out says so, and why, where its
  # row would otherwise say what it does (`Integrations.webhook_source/2`).
  def present(%{key: :webhooks}, source, view) do
    running = Integrations.webhook_source(view, source)
    goes = "#{events(source.adapter_kind)} go to #{destination(source)}"

    row(%{
      icon: :plug,
      name: source.name,
      state: running.state,
      text: running.reason || goes <> ".",
      meta: [
        running.reason && goes,
        credential(source),
        runs_in(view, source.environment_ref),
        grouping(source.group_by_labels)
      ],
      address: webhook_address(view, source.name)
    })
  end

  def present(section, item, _view) do
    [first | rest] = section.fields

    facts =
      for field <- rest,
          field.kind not in [:mapping, :lifecycle, :evidence],
          value = presented(field, item),
          do: "#{field.label} #{value}"

    row(%{
      name: presented(first, item) || to_string(Map.get(item, section.item_key)),
      meta: facts
    })
  end

  @doc "What removing a row does, said before it is done."
  @spec removal(map()) :: String.t()
  def removal(%{key: :pricing}),
    do: "Cost for this model will show as not priced unless another price covers it."

  def removal(%{key: :webhooks}),
    do: "Ryker stops accepting events at its address. Events already received stay."

  def removal(_section), do: "It is removed from these settings."

  @doc "The address a sender posts one source's events to."
  @spec webhook_address(map(), String.t()) :: String.t()
  def webhook_address(view, name),
    do: String.trim_trailing(view.webhook_base_url, "/") <> "/v1/hooks/" <> name

  @doc """
  A saved price per million tokens in dollars, as Settings and Usage print
  it: cents always, and more places only when the price has them ($0.125).
  """
  @spec usd(Decimal.t()) :: String.t()
  def usd(%Decimal{} = value) do
    rounded = Decimal.round(value, 2)

    if Decimal.equal?(rounded, value),
      do: "$" <> Decimal.to_string(rounded, :normal),
      else: "$" <> (value |> Decimal.normalize() |> Decimal.to_string(:normal))
  end

  defp row(fields) do
    Map.merge(%{icon: nil, state: nil, text: nil, meta: [], address: nil}, fields)
  end

  defp presented(field, item) do
    case SettingsSections.row_value(field, Map.get(item, field.name)) do
      value when value in ["", nil] -> nil
      value -> value
    end
  end

  defp model_name(target) do
    case Work.ExecutionTarget.parts(target) do
      %{model: model} -> model
      nil -> target || "Unnamed model"
    end
  end

  defp provider(target) do
    case Work.ExecutionTarget.present(target) do
      %{parts: %{provider: "codex"}} -> nil
      %{parts: %{provider: _provider}, meta: meta} -> meta
      _unparsed -> nil
    end
  end

  defp prices(rate) do
    [
      {rate.input_usd_per_million, "in"},
      {rate.cached_input_usd_per_million, "cached"},
      {rate.output_usd_per_million, "out"},
      {rate.reasoning_usd_per_million, "reasoning"}
    ]
    |> Enum.reject(fn {value, _word} -> is_nil(value) end)
    |> Enum.map(fn {value, word} -> "#{usd(value)} #{word}" end)
    |> List.update_at(-1, &(&1 <> " per million tokens"))
  end

  defp effective(nil), do: nil
  defp effective(%Date{} = date), do: "from " <> ShortTime.day(date, Date.utc_today())

  # A source that is a web address opens it; only http and https are links,
  # so a saved note can never become a script URL.
  defp source(provenance) do
    case URI.parse(provenance || "") do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:link, host <> (uri.path || ""), provenance}

      _note ->
        provenance
    end
  end

  defp events(:grafana), do: "Grafana alerts"
  defp events(:mapped_json), do: "Custom JSON events"
  defp events(_universal), do: "Events"

  defp destination(%{destination_transport: "slack", destination_conversation_ref: ref}),
    do: Slack.Names.destination(ref)

  defp destination(%{destination_transport: "control_plane"}), do: "a direct conversation"

  defp destination(%{destination_transport: "github", destination_conversation_ref: ref}),
    do: "GitHub #{ref}"

  defp destination(%{destination_conversation_ref: ref}), do: ref

  defp credential(%{auth_kind: :bearer, secret_name: name}), do: "Token #{name}"
  defp credential(%{secret_name: name}), do: "Signed with #{name}"

  defp grouping([]), do: nil
  defp grouping(labels), do: "Grouped by " <> Enum.join(labels, ", ")

  defp runs_in(_view, nil), do: nil
  defp runs_in(view, ref), do: "Runs in " <> named(view.snapshot.environments, ref)

  defp named(items, ref) do
    case Enum.find(items, &(&1.ref == ref)) do
      nil -> ref
      item -> name(item)
    end
  end

  defp name(%{display_name: name, ref: ref}) when name in [nil, ""], do: ref
  defp name(%{display_name: name}), do: name
end
