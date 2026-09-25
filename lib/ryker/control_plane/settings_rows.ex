defmodule Ryker.ControlPlane.SettingsRows do
  @moduledoc """
  How one saved row of a settings collection reads in a list: a name, its
  state, what it does and one line of facts. Identifiers a person needs only
  for support, such as a pinned policy version, go under a closed Details
  disclosure instead of the facts line.
  """

  alias Ryker.ControlPlane.{ExecutionTarget, SettingsSections, SlackNames}

  @type row :: %{
          name: String.t(),
          state: {atom(), String.t()} | nil,
          text: String.t() | nil,
          meta: [String.t() | {:strong, String.t()} | nil],
          details: [{String.t(), String.t()}],
          address: String.t() | nil
        }

  @spec present(map(), struct(), map()) :: row()
  def present(%{key: :pricing}, rate, _view) do
    row(%{
      name: model_name(rate.execution_target),
      meta:
        [provider(rate.execution_target)] ++
          prices(rate) ++ [effective(rate.effective_from), rate.provenance]
    })
  end

  def present(%{key: :webhooks}, source, view) do
    row(%{
      name: source.name,
      state: if(source.enabled, do: {:on, "On"}, else: {:off, "Off"}),
      text: "#{events(source.adapter_kind)} go to #{destination(source)}.",
      meta: [
        credential(source),
        runs_in(view, source.environment_ref),
        grouping(source.group_by_labels)
      ],
      address: webhook_address(view, source.name)
    })
  end

  def present(%{key: :policies} = section, binding, view) do
    status = row_status(section, binding, view)
    {state, text} = policy_state(status.tone, binding)

    row(%{
      name: option_label(section, :purpose, binding.purpose),
      state: state,
      text: text,
      meta: [
        policy_scope(view, binding),
        "Policy #{binding.policy_name}",
        offered(view, binding)
      ],
      details:
        Enum.reject(
          [
            {"Pinned version", binding.policy_digest},
            {"Authority", binding.authority_digest},
            {"Confirmed by",
             if(binding.verified_by == :import,
               do: "Imported",
               else: binding.verified_worker_ref
             )}
          ],
          fn {_label, value} -> value in [nil, ""] end
        )
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

  def removal(%{key: :policies}), do: "New work of this kind stops using this policy."
  def removal(_section), do: "It is removed from these settings."

  @doc "The address a sender posts one source's events to."
  @spec webhook_address(map(), String.t()) :: String.t()
  def webhook_address(view, name),
    do: String.trim_trailing(view.webhook_base_url, "/") <> "/v1/hooks/" <> name

  @doc "A saved date as a short day and month, with the year only when it is not this one."
  @spec short_date(Date.t()) :: String.t()
  def short_date(%Date{} = date) do
    if date.year == Date.utc_today().year,
      do: Calendar.strftime(date, "%-d %b"),
      else: Calendar.strftime(date, "%-d %b %Y")
  end

  defp row(fields) do
    Map.merge(%{state: nil, text: nil, meta: [], details: [], address: nil}, fields)
  end

  defp presented(field, item) do
    case SettingsSections.row_value(field, Map.get(item, field.name)) do
      value when value in ["", nil] -> nil
      value -> value
    end
  end

  defp model_name(target) do
    case ExecutionTarget.parts(target) do
      %{model: model} -> model
      nil -> target || "Unnamed model"
    end
  end

  defp provider(target) do
    case ExecutionTarget.present(target) do
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

  defp usd(%Decimal{} = value) do
    rounded = Decimal.round(value, 2)

    if Decimal.equal?(rounded, value),
      do: "$" <> Decimal.to_string(rounded, :normal),
      else: "$" <> (value |> Decimal.normalize() |> Decimal.to_string(:normal))
  end

  defp effective(nil), do: nil
  defp effective(%Date{} = date), do: "from " <> short_date(date)

  defp events(:grafana), do: "Grafana alerts"
  defp events(:mapped_json), do: "Custom JSON events"
  defp events(_universal), do: "Events"

  defp destination(%{destination_transport: "slack", destination_conversation_ref: ref}),
    do: SlackNames.destination(ref)

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

  # A policy applies everywhere, to one repository or to one environment; the
  # kind of scope says which list its ref names.
  defp policy_scope(_view, %{scope_kind: :installation}), do: "Everywhere"

  defp policy_scope(view, %{scope_kind: :repository, scope_ref: ref}),
    do: "Repository " <> named(view.snapshot.repositories, ref)

  defp policy_scope(view, %{scope_kind: :environment, scope_ref: ref}),
    do: "Environment " <> named(view.snapshot.environments, ref)

  defp named(items, ref) do
    case Enum.find(items, &(&1.ref == ref)) do
      nil -> ref
      item -> name(item)
    end
  end

  defp name(%{display_name: name, ref: ref}) when name in [nil, ""], do: ref
  defp name(%{display_name: name}), do: name

  defp row_status(%{row_status: {module, function}}, item, view),
    do: apply(module, function, [item, view])

  defp policy_state("verified", _binding), do: {{:on, "Ready"}, nil}

  defp policy_state("changed", _binding),
    do:
      {{:warn, "Changed on the workers"},
       "The workers now offer a different version. Ryker keeps running the version pinned here."}

  defp policy_state(_unavailable, %{verified_by: :import}),
    do:
      {{:warn, "Not confirmed"}, "It was imported, and no connected worker has confirmed it yet."}

  defp policy_state(_unavailable, _binding),
    do:
      {{:warn, "Unavailable"},
       "No connected worker offers this policy, so this kind of work cannot start."}

  defp offered(view, binding) do
    case Enum.filter(view.workers.policies, &(&1.name == binding.policy_name)) do
      [] -> nil
      advertisements -> "Offered by #{count(advertisements)}"
    end
  end

  defp count(advertisements) do
    case advertisements |> Enum.flat_map(& &1.workers) |> Enum.uniq() |> length() do
      1 -> "1 worker"
      workers -> "#{workers} workers"
    end
  end

  defp option_label(section, field_name, value) do
    field = Enum.find(section.fields, &(&1.name == field_name))
    SettingsSections.row_value(field, value)
  end
end
