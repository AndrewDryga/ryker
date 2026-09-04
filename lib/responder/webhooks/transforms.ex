defmodule Responder.Webhooks.Transforms do
  @moduledoc """
  Trusted provider transforms above the source-neutral webhook input.

  A transform may select bounded fields and derive source identity, but it
  cannot choose the destination, Work profile, credentials, or implementation
  module. Those remain part of the validated route.
  """

  alias Responder.CanonicalJSON
  alias Responder.Webhooks.{Input, Route}

  @maximum_alerts 500
  @maximum_revision 9_223_372_036_854_775_807
  @metadata_fields [
    :event_id,
    :event_type,
    :item_id,
    :occurred_at,
    :occurred_at_source,
    :revision
  ]

  @type result :: %{
          inputs: [Responder.Ingress.Input.t()],
          revision_ties: :exact | :receipt_order_unbounded
        }

  @spec normalize(Route.t(), term(), keyword() | map()) ::
          {:ok, result()} | {:error, term()}
  def normalize(%Route{adapter: %{kind: :universal}} = route, payload, metadata) do
    with {:ok, input} <- Input.new(route, payload, metadata) do
      {:ok, %{inputs: [input], revision_ties: :exact}}
    end
  end

  def normalize(%Route{adapter: %{kind: :grafana}} = route, payload, metadata) do
    with {:ok, metadata} <- metadata_map(metadata),
         {:ok, payload} <- object(payload, :payload),
         {:ok, alerts} <- alerts(payload),
         {:ok, common_labels} <- string_map(Map.get(payload, "commonLabels"), :labels),
         {:ok, common_annotations} <-
           string_map(Map.get(payload, "commonAnnotations"), :annotations),
         {:ok, inputs} <-
           map_grafana_alerts(route, payload, alerts, common_labels, common_annotations, metadata) do
      {:ok, %{inputs: inputs, revision_ties: :receipt_order_unbounded}}
    end
  end

  def normalize(%Route{adapter: %{kind: :mapped_json}} = route, payload, metadata) do
    with {:ok, metadata} <- metadata_map(metadata),
         {:ok, payload} <- object(payload, :payload),
         {:ok, input, revision_ties} <- mapped_input(route, payload, metadata) do
      {:ok, %{inputs: [input], revision_ties: revision_ties}}
    end
  end

  def normalize(_route, _payload, _metadata),
    do: {:error, {:invalid_webhook_transform, :route}}

  defp map_grafana_alerts(route, payload, alerts, common_labels, common_annotations, metadata) do
    alerts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {alert, index}, {:ok, inputs} ->
      case grafana_input(route, payload, alert, common_labels, common_annotations, metadata) do
        {:ok, input} -> {:cont, {:ok, [input | inputs]}}
        {:error, reason} -> {:halt, {:error, {:grafana_alert, index, reason}}}
      end
    end)
    |> case do
      {:ok, inputs} ->
        {:ok, Enum.reverse(inputs)}

      {:error, {:grafana_alert, _index, {:invalid_webhook_transform, field}}} ->
        {:error, {:invalid_webhook_transform, field}}
    end
  end

  defp grafana_input(route, payload, alert, common_labels, common_annotations, metadata) do
    with {:ok, alert} <- object(alert, :alerts),
         {:ok, labels} <- string_map(Map.get(alert, "labels"), :labels),
         {:ok, annotations} <- string_map(Map.get(alert, "annotations"), :annotations),
         {:ok, alert_status} <- optional_text(alert, "status", :status, 64),
         {:ok, payload_status} <- optional_text(payload, "status", :status, 64),
         {:ok, group_key} <-
           optional_identity_text(payload, "groupKey", :group_key, 1_024),
         {:ok, payload_title} <- optional_text(payload, "title", :title, 500),
         {:ok, payload_message} <- optional_text(payload, "message", :summary, 4_000),
         {:ok, external_url} <- optional_text(payload, "externalURL", :source_url, 2_000),
         {:ok, fingerprint} <-
           optional_identity_text(alert, "fingerprint", :fingerprint, 500),
         {:ok, panel_url} <- optional_text(alert, "panelURL", :source_url, 2_000),
         {:ok, dashboard_url} <- optional_text(alert, "dashboardURL", :source_url, 2_000),
         {:ok, generator_url} <- optional_text(alert, "generatorURL", :source_url, 2_000),
         labels <- Map.merge(common_labels, labels),
         annotations <- Map.merge(common_annotations, annotations),
         {:ok, status} <- status(first_nonempty([alert_status, payload_status])),
         {:ok, title} <-
           required_text(
             first_nonempty([
               annotations["summary"],
               annotations["title"],
               labels["alertname"],
               payload_title
             ]),
             :title,
             500
           ),
         {:ok, starts_at} <- optional_time(Map.get(alert, "startsAt"), :starts_at),
         {:ok, ends_at} <- optional_time(Map.get(alert, "endsAt"), :ends_at) do
      fingerprint = grafana_fingerprint(route, fingerprint, labels, starts_at)
      item_id = stable_id("grafana-item", [route.name, fingerprint, encoded_time(starts_at)])

      event_id =
        stable_id("grafana-event", [
          route.name,
          fingerprint,
          encoded_time(starts_at),
          status,
          encoded_time(ends_at),
          annotations
        ])

      occurrence = occurrence_time(status, starts_at, ends_at, metadata)

      normalized = %{
        "adapter" => "grafana",
        "annotations" => bounded_map(annotations),
        "correlation_key" => correlation_key(route, group_key, labels, fingerprint),
        "ends_at" => encoded_time(ends_at),
        "labels" => bounded_map(labels),
        "severity" =>
          first_nonempty([labels["severity"], labels["priority"], labels["level"]])
          |> optional_bounded(64),
        "source_fingerprint" => fingerprint,
        "source_incident_id" => group_key,
        "source_url" => grafana_url([panel_url, dashboard_url, generator_url, external_url]),
        "starts_at" => encoded_time(starts_at),
        "status" => status,
        "summary" =>
          first_nonempty([
            annotations["description"],
            annotations["message"],
            payload_message
          ])
          |> optional_bounded(4_000),
        "title" => title
      }

      Input.new(route, normalized, %{
        event_id: event_id,
        event_type: "grafana.alert.#{status}",
        item_id: item_id,
        occurred_at: occurrence.value,
        occurred_at_source: occurrence.source,
        revision: 1
      })
    end
  end

  defp mapped_input(%Route{adapter: %{mapping: mapping}} = route, payload, metadata) do
    with {:ok, event_id} <-
           mapped_required_identity(payload, mapping.event_id, :event_id, 1_024),
         {:ok, raw_status} <- mapped_required(payload, mapping.status, :status, 64),
         {:ok, status} <- status(raw_status),
         {:ok, title} <- mapped_required(payload, mapping.title, :title, 500),
         {:ok, item_id} <-
           mapped_optional_identity(payload, mapping.item_id, :item_id, 1_024),
         {:ok, incident_id} <-
           mapped_optional_identity(payload, mapping.incident_id, :incident_id, 1_024),
         {:ok, severity} <- mapped_optional(payload, mapping.severity, :severity, 64),
         {:ok, summary} <- mapped_optional(payload, mapping.summary, :summary, 4_000),
         {:ok, source_url} <- mapped_url(payload, mapping.source_url),
         {:ok, labels} <- mapped_map(payload, mapping.labels, :labels),
         {:ok, annotations} <- mapped_map(payload, mapping.annotations, :annotations),
         {:ok, starts_at} <- mapped_time(payload, mapping.starts_at, :starts_at),
         {:ok, ends_at} <- mapped_time(payload, mapping.ends_at, :ends_at),
         {:ok, revision, revision_ties} <- mapped_revision(payload, mapping.revision) do
      source_item = first_nonempty([item_id, incident_id, event_id])
      occurrence = occurrence_time(status, starts_at, ends_at, metadata)

      normalized = %{
        "adapter" => "mapped_json",
        "annotations" => bounded_map(labels_or_empty(annotations)),
        "correlation_key" =>
          correlation_key(route, incident_id, labels_or_empty(labels), source_item),
        "ends_at" => encoded_time(ends_at),
        "external_event_id" => event_id,
        "labels" => bounded_map(labels_or_empty(labels)),
        "severity" => severity,
        "source_incident_id" => incident_id,
        "source_url" => source_url,
        "starts_at" => encoded_time(starts_at),
        "status" => status,
        "summary" => summary,
        "title" => title
      }

      case Input.new(route, normalized, %{
             event_id: stable_id("mapped-event", [route.name, event_id]),
             event_type: "mapped_json.alert.#{status}",
             item_id: stable_id("mapped-item", [route.name, source_item]),
             occurred_at: occurrence.value,
             occurred_at_source: occurrence.source,
             revision: revision
           }) do
        {:ok, input} -> {:ok, input, revision_ties}
        {:error, _reason} = error -> error
      end
    end
  end

  defp metadata_map(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata) and Enum.uniq(Keyword.keys(metadata)) == Keyword.keys(metadata),
      do: metadata_map(Map.new(metadata)),
      else: transform_error(:metadata)
  end

  defp metadata_map(%{} = metadata) do
    validations = [
      optional_reference?(metadata[:event_id], 1_024),
      optional_reference?(metadata[:event_type], 256),
      optional_reference?(metadata[:item_id], 1_024),
      utc_datetime?(metadata[:occurred_at]),
      metadata[:occurred_at_source] in [:source, :ingress],
      valid_revision?(metadata[:revision])
    ]

    valid =
      Map.keys(metadata) |> Enum.sort() == Enum.sort(@metadata_fields) and Enum.all?(validations)

    if valid, do: {:ok, metadata}, else: transform_error(:metadata)
  end

  defp metadata_map(_metadata), do: transform_error(:metadata)

  defp alerts(%{"alerts" => alerts})
       when is_list(alerts) and length(alerts) in 1..@maximum_alerts,
       do: {:ok, alerts}

  defp alerts(_payload), do: transform_error(:alerts)

  defp object(nil, _field), do: {:ok, %{}}
  defp object(value, _field) when is_map(value), do: {:ok, value}
  defp object(_value, field), do: transform_error(field)

  defp string_map(nil, _field), do: {:ok, %{}}

  defp string_map(value, field) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end),
      do: {:ok, value},
      else: transform_error(field)
  end

  defp string_map(_value, field), do: transform_error(field)

  defp mapped_required(payload, path, field, maximum) do
    case lookup(payload, path) do
      {:ok, value} -> required_scalar(value, field, maximum)
      :error -> transform_error(field)
    end
  end

  defp mapped_required_identity(payload, path, field, maximum) do
    case lookup(payload, path) do
      {:ok, value} -> identity_scalar(value, field, maximum)
      :error -> transform_error(field)
    end
  end

  defp mapped_optional(_payload, nil, _field, _maximum), do: {:ok, nil}

  defp mapped_optional(payload, path, field, maximum) do
    case lookup(payload, path) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> scalar(value, field, maximum)
    end
  end

  defp mapped_optional_identity(_payload, nil, _field, _maximum), do: {:ok, nil}

  defp mapped_optional_identity(payload, path, field, maximum) do
    case lookup(payload, path) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> identity_scalar(value, field, maximum)
    end
  end

  defp mapped_map(_payload, nil, _field), do: {:ok, nil}

  defp mapped_map(payload, path, field) do
    case lookup(payload, path) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_map(value) -> scalar_map(value, field)
      {:ok, _value} -> transform_error(field)
    end
  end

  defp mapped_time(_payload, nil, _field), do: {:ok, nil}

  defp mapped_time(payload, path, field) do
    case lookup(payload, path) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> optional_time(value, field)
    end
  end

  defp mapped_url(_payload, nil), do: {:ok, nil}

  defp mapped_url(payload, path) do
    with {:ok, value} <- mapped_optional(payload, path, :source_url, 2_000) do
      if is_nil(value) or valid_url?(value), do: {:ok, value}, else: transform_error(:source_url)
    end
  end

  defp mapped_revision(_payload, nil), do: {:ok, 1, :receipt_order_unbounded}

  defp mapped_revision(payload, path) do
    case lookup(payload, path) do
      :error -> {:ok, 1, :receipt_order_unbounded}
      {:ok, nil} -> {:ok, 1, :receipt_order_unbounded}
      {:ok, value} -> positive_revision(value)
    end
  end

  defp positive_revision(value) when is_integer(value) and value > 0,
    do: {:ok, value, :exact}

  defp positive_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} when revision > 0 -> {:ok, revision, :exact}
      _invalid -> transform_error(:revision)
    end
  end

  defp positive_revision(_value), do: transform_error(:revision)

  defp lookup(payload, path) do
    path
    |> String.split(".")
    |> Enum.reduce_while({:ok, payload}, fn segment, {:ok, current} ->
      case current do
        %{^segment => value} -> {:cont, {:ok, value}}
        _other -> {:halt, :error}
      end
    end)
  end

  defp required_scalar(value, field, maximum) do
    with {:ok, value} <- scalar(value, field, maximum),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> transform_error(field)
    end
  end

  defp scalar(value, _field, maximum) when is_binary(value),
    do: {:ok, bounded(value, maximum)}

  defp scalar(value, _field, maximum) when is_integer(value) or is_float(value),
    do: {:ok, value |> to_string() |> bounded(maximum)}

  defp scalar(value, _field, maximum) when is_boolean(value),
    do: {:ok, value |> to_string() |> bounded(maximum)}

  defp scalar(_value, field, _maximum), do: transform_error(field)

  defp identity_scalar(value, field, maximum) when is_binary(value) do
    value = String.trim(value)

    if String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and value != "" and
         byte_size(value) <= maximum,
       do: {:ok, value},
       else: transform_error(field)
  end

  defp identity_scalar(value, field, maximum)
       when is_integer(value) or is_float(value) or is_boolean(value),
       do: value |> to_string() |> identity_scalar(field, maximum)

  defp identity_scalar(_value, field, _maximum), do: transform_error(field)

  defp scalar_map(value, field) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, item}, {:ok, result} when is_binary(key) ->
        case scalar(item, field, 1_000) do
          {:ok, scalar} -> {:cont, {:ok, Map.put(result, bounded(key, 128), scalar)}}
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _result ->
        {:halt, transform_error(field)}
    end)
  end

  defp status(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["firing", "alerting", "active", "open", "triggered"] ->
        {:ok, "firing"}

      value when value in ["resolved", "ok", "closed", "normal", "recovered"] ->
        {:ok, "resolved"}

      _unsupported ->
        transform_error(:status)
    end
  end

  defp status(_value), do: transform_error(:status)

  defp optional_time(nil, _field), do: {:ok, nil}
  defp optional_time("", _field), do: {:ok, nil}

  defp optional_time(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> transform_error(field)
    end
  end

  defp optional_time(_value, field), do: transform_error(field)

  defp required_text(value, field, maximum) when is_binary(value) do
    value = bounded(value, maximum)
    if value == "", do: transform_error(field), else: {:ok, value}
  end

  defp required_text(_value, field, _maximum), do: transform_error(field)

  defp optional_text(map, key, field, maximum) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, optional_bounded(value, maximum)}
      {:ok, _value} -> transform_error(field)
    end
  end

  defp optional_identity_text(map, key, field, maximum) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "", do: {:ok, nil}, else: identity_scalar(value, field, maximum)

      {:ok, _value} ->
        transform_error(field)
    end
  end

  defp grafana_fingerprint(route, value, labels, starts_at) do
    case value do
      nil -> CanonicalJSON.digest([route.name, labels, encoded_time(starts_at)])
      fingerprint -> fingerprint
    end
  end

  defp grafana_url(values) do
    case first_nonempty(values) do
      nil -> nil
      value -> if valid_url?(value), do: value
    end
  end

  defp valid_url?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _invalid ->
        false
    end
  end

  defp correlation_key(route, incident_id, labels, source_id) do
    repository = if route.work_profile, do: route.work_profile.repository_ref || "", else: ""

    cond do
      incident_id ->
        CanonicalJSON.digest([route.name, repository, "incident", incident_id])

      grouped = grouped_labels(route.adapter.group_by_labels, labels) ->
        CanonicalJSON.digest([route.name, repository, "labels", grouped])

      true ->
        CanonicalJSON.digest([route.name, repository, "source", source_id])
    end
  end

  defp grouped_labels(names, labels) do
    values = Map.new(names, &{&1, Map.get(labels, &1)})
    if Enum.any?(values, fn {_name, value} -> value not in [nil, ""] end), do: values
  end

  defp occurrence_time("resolved", _starts_at, %DateTime{} = ends_at, _metadata),
    do: %{source: :source, value: ends_at}

  defp occurrence_time(_status, %DateTime{} = starts_at, _ends_at, _metadata),
    do: %{source: :source, value: starts_at}

  defp occurrence_time(_status, _starts_at, _ends_at, metadata),
    do: %{source: metadata.occurred_at_source, value: metadata.occurred_at}

  defp stable_id(prefix, values), do: "#{prefix}:#{CanonicalJSON.digest(values)}"

  defp bounded_map(values) when map_size(values) == 0, do: nil

  defp bounded_map(values) do
    values
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(64)
    |> Map.new(fn {key, value} -> {bounded(key, 128), bounded(value, 1_000)} end)
  end

  defp labels_or_empty(nil), do: %{}
  defp labels_or_empty(value), do: value

  defp first_nonempty(values) do
    Enum.find(values, fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp optional_bounded(value, maximum) when is_binary(value) do
    case bounded(value, maximum) do
      "" -> nil
      value -> value
    end
  end

  defp optional_bounded(_value, _maximum), do: nil

  defp optional_reference?(nil, _maximum), do: true

  defp optional_reference?(value, maximum) when is_binary(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp optional_reference?(_value, _maximum), do: false

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false

  defp valid_revision?(value),
    do: is_integer(value) and value > 0 and value <= @maximum_revision

  defp bounded(value, maximum) do
    value = value |> String.replace(<<0>>, "") |> String.trim()

    if byte_size(value) <= maximum do
      value
    else
      value |> bounded_codepoints(maximum) |> IO.iodata_to_binary()
    end
  end

  defp bounded_codepoints(value, maximum) do
    {codepoints, _size} =
      value
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, &take_codepoint(&1, &2, maximum))

    Enum.reverse(codepoints)
  end

  defp take_codepoint(codepoint, {codepoints, size}, maximum) do
    next_size = size + byte_size(codepoint)

    if next_size <= maximum,
      do: {:cont, {[codepoint | codepoints], next_size}},
      else: {:halt, {codepoints, size}}
  end

  defp encoded_time(nil), do: nil
  defp encoded_time(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp transform_error(field), do: {:error, {:invalid_webhook_transform, field}}
end
