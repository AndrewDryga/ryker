defmodule Ryker.ControlPlane.ConfigurationProjection do
  @moduledoc """
  The effective configuration as the running node holds it: which runtimes are
  enabled, the values an operator can compare against the durable settings,
  and the capability and tool grants by name. Values are printed only when
  they are scalars; credentials, callbacks and schemas never appear.
  """

  @owners ~w(admission work control_plane coop_worker_gateway delivery publication retention state_tools event_waits schedules emisar slack github webhooks)a

  @doc "What the running node holds, labelled by the source it was applied from."
  def fetch do
    source = "durable settings"

    %{
      grants: mcp_grants(source),
      rows: configuration_rows(source),
      source: source
    }
  end

  defp configuration_rows(source) do
    presence =
      Enum.map(@owners, fn owner ->
        %{
          key: Atom.to_string(owner),
          source: source,
          value: if(Application.get_env(:ryker, owner), do: "enabled", else: "disabled")
        }
      end)

    admission = Application.get_env(:ryker, :admission, %{})
    work = Application.get_env(:ryker, :work, %{})
    retention = Application.get_env(:ryker, :retention, %{})

    details =
      []
      |> maybe_config("runtime.mode", Application.get_env(:ryker, :runtime_mode), source)
      |> maybe_config("admission.policy", safe_value(admission, :policy), source)
      |> maybe_config(
        "admission.decision_timeout_ms",
        safe_value(admission, :decision_timeout_ms),
        source
      )
      |> maybe_config("work.concurrency", safe_value(work, :concurrency), source)
      |> maybe_config("work.poll_interval_ms", safe_value(work, :poll_interval_ms), source)
      |> maybe_config(
        "retention.operational_data_seconds",
        safe_value(retention, :operational_data_seconds),
        source
      )
      |> maybe_config(
        "retention.closed_work_seconds",
        safe_value(retention, :closed_work_seconds),
        source
      )
      |> maybe_config(
        "retention.episode_history_seconds",
        safe_value(retention, :episode_history_seconds),
        source
      )
      |> maybe_config(
        "retention.audit_data_seconds",
        safe_value(retention, :audit_data_seconds),
        source
      )
      |> maybe_config(
        "retention.disposable_bytes_limit",
        safe_value(retention, :disposable_bytes_limit),
        source
      )
      |> maybe_config(
        "retention.reclaim_target_seconds",
        safe_value(retention, :reclaim_target_seconds),
        source
      )
      |> maybe_config(
        "retention.storage_high_watermark_bytes",
        safe_value(retention, :storage_high_watermark_bytes),
        source
      )
      |> maybe_config(
        "retention.storage_low_watermark_bytes",
        safe_value(retention, :storage_low_watermark_bytes),
        source
      )
      |> maybe_config(
        "retention.storage_reserve_bytes",
        safe_value(retention, :storage_reserve_bytes),
        source
      )

    presence ++ Enum.reverse(details)
  end

  defp mcp_grants(source) do
    state_tools = Application.get_env(:ryker, :state_tools, %{})
    work = Application.get_env(:ryker, :work, %{})

    capabilities =
      state_tools
      |> safe_list(:capabilities)
      |> Enum.filter(&(is_atom(&1) or is_binary(&1)))
      |> Enum.map(&to_string/1)

    tools =
      state_tools
      |> safe_list(:additional_tools)
      |> Enum.flat_map(fn
        %{"name" => name} when is_binary(name) -> [name]
        %{name: name} when is_binary(name) -> [name]
        _invalid -> []
      end)

    platform_tools =
      work
      |> safe_list(:platform_tools)
      |> Enum.filter(&is_binary/1)

    (Enum.map(capabilities, &%{kind: "host capability", name: &1, source: source}) ++
       Enum.map(tools, &%{kind: "MCP tool", name: &1, source: source}) ++
       Enum.map(platform_tools, &%{kind: "source/action tool", name: &1, source: source}))
    |> Enum.uniq_by(&{&1.kind, &1.name})
    |> Enum.sort_by(&{&1.kind, &1.name})
    |> Enum.take(512)
  end

  defp maybe_config(rows, _key, nil, _source), do: rows

  defp maybe_config(rows, key, value, source)
       when is_binary(value) or is_atom(value) or is_integer(value) or is_boolean(value),
       do: [%{key: key, source: source, value: to_string(value)} | rows]

  defp maybe_config(rows, _key, _value, _source), do: rows

  defp safe_value(value, key) when is_map(value), do: Map.get(value, key)
  defp safe_value(_value, _key), do: nil

  defp safe_list(value, key) when is_map(value) do
    case Map.get(value, key, []) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp safe_list(_value, _key), do: []
end
