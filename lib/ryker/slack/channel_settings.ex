defmodule Ryker.Slack.ChannelSettings do
  @moduledoc """
  One effective participation setting per Slack channel.

  A channel row holds the explicit choice; no row, or a row with no
  participation, inherits the installation default. Inheritance is stored as
  inheritance rather than as a copied default, so moving the installation
  default reaches every channel that never chose for itself and disturbs none
  that did. This module owns settings only: operator and Slack membership
  authorization stay at the command or control boundary, except the
  installation default, whose write is authorized by saved operator membership.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Repo
  alias Ryker.Settings

  alias Ryker.Slack.{
    ChannelConfiguration,
    ChannelConfigurationChangeset,
    ChannelSettingAudit,
    ChannelSettingChangeset
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
  @participation [:mentions, :proactive, :shadow]

  @spec change(map() | keyword(), atom() | nil) :: {:ok, map()} | {:error, term()}
  def change(attributes, default_participation \\ nil) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- validate(attributes),
         {:ok, default} <- default_participation(default_participation, attributes.workspace_ref) do
      Repo.transaction(fn -> change_locked(attributes, default) end) |> transaction_result()
    end
  end

  @doc """
  The effective participation of one conversation.

  `default_participation` is the installation default the caller already
  resolved, so the hot path reads one channel row and never the settings store.
  """
  @spec effective(String.t(), String.t(), atom()) :: map() | {:error, term()}
  def effective(workspace_ref, conversation_ref, default_participation) do
    with :ok <- reference(workspace_ref, :workspace_ref, 256),
         :ok <- conversation(workspace_ref, conversation_ref),
         :ok <- participation(default_participation, :default_participation) do
      workspace_ref
      |> configuration(channel_ref(conversation_ref))
      |> resolve(default_participation)
    end
  end

  @doc "The effective participation as one value, for surfaces that show a choice."
  @spec effective_participation(map()) :: %{source: atom(), value: atom()}
  def effective_participation(%{proactive: proactive, shadow: shadow}) do
    cond do
      shadow.value -> %{source: shadow.source, value: :shadow}
      proactive.value -> %{source: proactive.source, value: :proactive}
      true -> %{source: proactive.source, value: :mentions}
    end
  end

  defp resolve(%ChannelConfiguration{participation: saved}, _default)
       when saved in @participation,
       do: document(:channel, saved)

  defp resolve(_inherited, default), do: document(:installation, default)

  defp document(source, participation) do
    %{
      proactive: %{source: source, value: participation == :proactive},
      shadow: %{source: source, value: participation == :shadow}
    }
  end

  defp change_locked(attributes, default) do
    fingerprint = fingerprint(attributes)

    case Repo.one(
           from(event in ChannelSettingAudit,
             where: event.event_ref == ^attributes.event_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %ChannelSettingAudit{request_fingerprint: ^fingerprint} ->
        %{effective: effective!(attributes, default), status: :duplicate}

      %ChannelSettingAudit{} ->
        Repo.rollback(:channel_setting_event_conflict)

      nil ->
        default = apply_change!(attributes, default)
        insert_audit!(attributes, fingerprint)
        %{effective: effective!(attributes, default), status: :updated}
    end
  end

  # A workspace-scoped command is an installation default edit. It goes through
  # the settings store so one writer owns the value and its provenance.
  defp apply_change!(%{scope: :workspace} = attributes, default) do
    target = target_participation(attributes, default)

    case Settings.save_default_participation(target, "slack:user:#{attributes.actor_ref}") do
      {:ok, saved} -> saved.slack.default_participation
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_change!(%{scope: :channel} = attributes, default) do
    configuration = locked_configuration!(attributes)
    if is_nil(configuration), do: Repo.rollback(:configuration_not_found)

    target =
      case attributes.value do
        :inherit -> nil
        _explicit -> target_participation(attributes, configuration.participation || default)
      end

    unless configuration.participation == target do
      configuration
      |> ChannelConfigurationChangeset.configuration(%{
        actor_ref: attributes.actor_ref,
        participation: target,
        revision: configuration.revision + 1,
        saved_at: attributes.occurred_at
      })
      |> Repo.update!()
    end

    default
  end

  # Turning one setting on clears the other: a channel is observed silently, or
  # replied to proactively, never both.
  defp target_participation(%{setting: setting, value: :on}, _current), do: setting

  defp target_participation(%{setting: setting}, current),
    do: if(current == setting, do: :mentions, else: current || :mentions)

  defp locked_configuration!(attributes) do
    Repo.one(
      from(configuration in ChannelConfiguration,
        where:
          configuration.workspace_ref == ^attributes.workspace_ref and
            configuration.channel_ref == ^channel_ref(attributes.conversation_ref),
        lock: "FOR UPDATE"
      )
    )
  end

  defp insert_audit!(attributes, fingerprint) do
    %{
      actor_ref: attributes.actor_ref,
      conversation_ref: attributes.conversation_ref,
      detail: %{
        "scope" => Atom.to_string(attributes.scope),
        "setting" => Atom.to_string(attributes.setting),
        "value" => Atom.to_string(attributes.value)
      },
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

  defp effective!(attributes, default),
    do: effective(attributes.workspace_ref, attributes.conversation_ref, default)

  defp default_participation(nil, workspace_ref) do
    case Repo.one(
           from(slack in Settings.Slack,
             select: {slack.workspace_ref, slack.default_participation}
           )
         ) do
      {^workspace_ref, default} -> {:ok, default}
      _other -> {:error, {:invalid_channel_setting, :workspace_ref}}
    end
  end

  defp default_participation(default, _workspace_ref) do
    case participation(default, :default_participation) do
      :ok -> {:ok, default}
      {:error, _reason} = error -> error
    end
  end

  defp configuration(workspace_ref, channel_ref) do
    Repo.get_by(ChannelConfiguration, workspace_ref: workspace_ref, channel_ref: channel_ref)
  end

  defp channel_ref(conversation_ref),
    do: conversation_ref |> String.split(":", parts: 3) |> List.last()

  defp fingerprint(attributes) do
    attributes
    |> Map.update!(:occurred_at, &DateTime.to_iso8601/1)
    |> Map.new(fn {key, value} ->
      {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
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
         ["slack", ^workspace_ref, channel] <- String.split(value, ":", parts: 3),
         :ok <- reference(channel, :conversation_ref, 256) do
      :ok
    else
      _invalid -> {:error, {:invalid_channel_setting, :conversation_ref}}
    end
  end

  defp participation(value, field) do
    if value in @participation, do: :ok, else: {:error, {:invalid_channel_setting, field}}
  end

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
