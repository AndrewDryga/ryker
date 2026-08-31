defmodule Responder.Slack.ChannelSettings do
  @moduledoc """
  Durable, audited Slack participation overrides.

  Channel overrides win over confirmed channel setup, then workspace overrides,
  then deployment defaults. `inherit` deletes an override instead of copying a
  default that may later change. This module owns settings only; operator and
  Slack membership authorization remain at the command or control boundary.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelSettingAudit,
    ChannelSettingChangeset,
    ChannelSettingOverride
  }

  @fields [
    :actor_ref,
    :conversation_ref,
    :event_ref,
    :occurred_at,
    :scope,
    :setting,
    :value,
    :workspace_ref
  ]
  @settings [:proactive, :shadow]
  @scopes [:channel, :workspace]
  @values [:inherit, :off, :on]

  @spec change(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def change(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- validate(attributes) do
      Repo.transaction(fn -> change_locked(attributes) end)
      |> transaction_result()
    end
  end

  @spec effective(String.t(), String.t(), map()) :: map() | {:error, term()}
  def effective(workspace_ref, conversation_ref, defaults) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- conversation(workspace_ref, conversation_ref),
         :ok <- defaults(defaults) do
      overrides =
        Repo.all(
          from(setting in ChannelSettingOverride,
            where:
              setting.workspace_ref == ^workspace_ref and
                ((setting.scope_kind == :channel and setting.scope_ref == ^conversation_ref) or
                   (setting.scope_kind == :workspace and setting.scope_ref == ^workspace_ref)),
            order_by: [asc: setting.scope_kind, asc: setting.setting]
          )
        )

      configuration =
        Repo.get_by(ChannelConfiguration,
          workspace_ref: workspace_ref,
          channel_ref: channel_ref(conversation_ref)
        )

      Map.new(@settings, fn setting ->
        {setting, resolve(setting, overrides, configuration, defaults)}
      end)
    end
  end

  defp change_locked(attributes) do
    fingerprint = fingerprint(attributes)

    case Repo.one(
           from(event in ChannelSettingAudit,
             where: event.event_ref == ^attributes.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ChannelSettingAudit{request_fingerprint: ^fingerprint} ->
        effective = effective!(attributes)
        %{effective: effective, status: :duplicate}

      %ChannelSettingAudit{} ->
        Repo.rollback(:channel_setting_event_conflict)

      nil ->
        apply_override(attributes)
        insert_audit!(attributes, fingerprint)
        %{effective: effective!(attributes), status: :updated}
    end
  end

  defp apply_override(%{value: :inherit} = attributes) do
    {scope_kind, scope_ref} = scope(attributes)

    Repo.delete_all(
      from(setting in ChannelSettingOverride,
        where:
          setting.workspace_ref == ^attributes.workspace_ref and
            setting.scope_kind == ^scope_kind and setting.scope_ref == ^scope_ref and
            setting.setting == ^attributes.setting
      )
    )

    :ok
  end

  defp apply_override(attributes) do
    {scope_kind, scope_ref} = scope(attributes)

    existing =
      Repo.one(
        from(setting in ChannelSettingOverride,
          where:
            setting.workspace_ref == ^attributes.workspace_ref and
              setting.scope_kind == ^scope_kind and setting.scope_ref == ^scope_ref and
              setting.setting == ^attributes.setting,
          lock: "FOR UPDATE"
        )
      )

    values = %{
      actor_ref: attributes.actor_ref,
      event_ref: attributes.event_ref,
      value: attributes.value == :on
    }

    case existing do
      %ChannelSettingOverride{} = setting ->
        setting
        |> ChannelSettingChangeset.update_override(
          Map.put(values, :revision, setting.revision + 1)
        )
        |> Repo.update!()

      nil ->
        values
        |> Map.merge(%{
          id: Ecto.UUID.generate(),
          revision: 1,
          scope_kind: scope_kind,
          scope_ref: scope_ref,
          setting: attributes.setting,
          workspace_ref: attributes.workspace_ref
        })
        |> ChannelSettingChangeset.insert_override()
        |> Repo.insert!()
    end

    :ok
  end

  defp insert_audit!(attributes, fingerprint) do
    detail = %{
      "scope" => Atom.to_string(attributes.scope),
      "setting" => Atom.to_string(attributes.setting),
      "value" => Atom.to_string(attributes.value)
    }

    %{
      actor_ref: attributes.actor_ref,
      conversation_ref: attributes.conversation_ref,
      detail: detail,
      event_ref: attributes.event_ref,
      id: Ecto.UUID.generate(),
      occurred_at: attributes.occurred_at,
      outcome: :updated,
      request_fingerprint: fingerprint,
      workspace_ref: attributes.workspace_ref
    }
    |> ChannelSettingChangeset.insert_audit()
    |> Repo.insert!()
  end

  defp effective!(attributes) do
    effective(
      attributes.workspace_ref,
      attributes.conversation_ref,
      %{proactive: false, shadow: false}
    )
  end

  defp resolve(setting, overrides, configuration, defaults) do
    channel =
      Enum.find(overrides, &(&1.setting == setting and &1.scope_kind == :channel))

    workspace =
      Enum.find(overrides, &(&1.setting == setting and &1.scope_kind == :workspace))

    cond do
      channel ->
        %{source: :channel, value: channel.value}

      configuration ->
        %{source: :configuration, value: configuration_value(configuration, setting)}

      workspace ->
        %{source: :workspace, value: workspace.value}

      true ->
        %{source: :deployment, value: Map.fetch!(defaults, setting)}
    end
  end

  defp configuration_value(%ChannelConfiguration{participation: :proactive}, :proactive), do: true
  defp configuration_value(%ChannelConfiguration{participation: :shadow}, :shadow), do: true
  defp configuration_value(%ChannelConfiguration{}, _setting), do: false

  defp channel_ref(conversation_ref),
    do: conversation_ref |> String.split(":", parts: 3) |> List.last()

  defp scope(%{scope: :channel, conversation_ref: ref}), do: {:channel, ref}
  defp scope(%{scope: :workspace, workspace_ref: ref}), do: {:workspace, ref}

  defp fingerprint(attributes) do
    attributes
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> Map.new(fn {key, value} ->
      value = if is_atom(value), do: Atom.to_string(value), else: value
      {Atom.to_string(key), value}
    end)
    |> CanonicalJSON.digest()
  end

  defp validate(attributes) do
    with :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.event_ref, :event_ref),
         :ok <- reference(attributes.workspace_ref, :workspace_ref, 256),
         :ok <- conversation(attributes.workspace_ref, attributes.conversation_ref),
         :ok <- member(attributes.scope, @scopes, :scope),
         :ok <- member(attributes.setting, @settings, :setting),
         :ok <- member(attributes.value, @values, :value) do
      utc(attributes.occurred_at)
    end
  end

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_channel_setting, :fields}}
  end

  defp attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_channel_setting, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_channel_setting, :fields}}

  defp conversation(workspace_ref, value) do
    with :ok <- reference(value, :conversation_ref),
         ["slack", ^workspace_ref, channel_ref] <- String.split(value, ":", parts: 3),
         :ok <- reference(channel_ref, :conversation_ref, 256) do
      :ok
    else
      _invalid -> {:error, {:invalid_channel_setting, :conversation_ref}}
    end
  end

  defp defaults(%{proactive: proactive, shadow: shadow} = defaults)
       when map_size(defaults) == 2 and is_boolean(proactive) and is_boolean(shadow),
       do: :ok

  defp defaults(_defaults), do: {:error, {:invalid_channel_setting, :defaults}}

  defp member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_channel_setting, field}}
  end

  defp utc(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0,
      do: :ok,
      else: {:error, {:invalid_channel_setting, :occurred_at}}
  end

  defp utc(_value), do: {:error, {:invalid_channel_setting, :occurred_at}}

  defp reference(value, field, maximum \\ 1_024) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_channel_setting, field}}
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
