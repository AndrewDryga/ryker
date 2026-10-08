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
  alias Ryker.CanonicalJSON
  alias Ryker.ConversationRef
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfiguration
  alias Ryker.Slack.ChannelConfigurations
  alias Ryker.Slack.ChannelSettingAudit

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
      Settings.atomically(fn -> {:ok, change_locked(attributes, default)} end)
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
      |> configuration(ConversationRef.slack_channel(conversation_ref))
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

    audit =
      attributes.event_ref
      |> ChannelSettingAudit.Query.by_event_ref()
      |> ChannelSettingAudit.Query.lock_for_update()
      |> Repo.fetch()

    case audit do
      {:ok, %ChannelSettingAudit{request_fingerprint: ^fingerprint}} ->
        %{effective: effective!(attributes, default), status: :duplicate}

      {:ok, %ChannelSettingAudit{}} ->
        Repo.rollback(:channel_setting_event_conflict)

      {:error, :not_found} ->
        default = apply_change!(attributes, default)
        insert_audit!(attributes, fingerprint)

        ChannelConfigurations.broadcast_channel_updated(
          attributes.workspace_ref,
          ConversationRef.slack_channel(attributes.conversation_ref)
        )

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

    target =
      case attributes.value do
        :inherit -> nil
        _explicit -> target_participation(attributes, configuration.participation || default)
      end

    unless configuration.participation == target do
      configuration
      |> ChannelConfiguration.Changeset.update(%{
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
    locked =
      attributes.workspace_ref
      |> ChannelConfiguration.Query.by_channel(
        ConversationRef.slack_channel(attributes.conversation_ref)
      )
      |> ChannelConfiguration.Query.lock_for_update()

    case Repo.fetch(locked) do
      {:ok, configuration} -> configuration
      {:error, :not_found} -> Repo.rollback(:configuration_not_found)
    end
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
      id: Repo.generate_id(),
      occurred_at: attributes.occurred_at,
      outcome: :updated,
      request_fingerprint: fingerprint,
      workspace_ref: attributes.workspace_ref
    }
    |> ChannelSettingAudit.Changeset.insert()
    |> Repo.insert!()
  end

  defp effective!(attributes, default),
    do: effective(attributes.workspace_ref, attributes.conversation_ref, default)

  defp default_participation(nil, workspace_ref) do
    case Repo.fetch(Settings.Slack.Query.select_default_participation()) do
      {:ok, {^workspace_ref, default}} -> {:ok, default}
      _other -> {:error, {:invalid_channel_setting, :workspace_ref}}
    end
  end

  defp default_participation(default, _workspace_ref) do
    case participation(default, :default_participation) do
      :ok -> {:ok, default}
      {:error, reason} -> {:error, reason}
    end
  end

  defp configuration(workspace_ref, channel_ref) do
    workspace_ref |> ChannelConfiguration.Query.by_channel(channel_ref) |> Repo.one()
  end

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
    if Maps.exact_keys?(attributes, @fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_channel_setting, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_channel_setting, :fields}}

  defp conversation(workspace_ref, value) do
    with :ok <- reference(value, :conversation_ref),
         {:ok, ^workspace_ref, channel} <- ConversationRef.parse_slack(value),
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

  defp reference(value, field, maximum \\ 1_024),
    do: Reference.check(value, field, :invalid_channel_setting, maximum)
end
