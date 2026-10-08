defmodule Ryker.ControlPlane.SettingsCommands do
  @moduledoc """
  A console person's writes into durable product settings, recorded as
  `actor_ref` (`Ryker.ControlPlane.Actor.of/1`).

  Each command names a section from the catalog, casts its form into typed
  attributes and hands them to `Ryker.Settings`, which owns authorization,
  the expected revision, whole-changeset validation and the edit receipt.
  Nothing here writes a row or decides what is allowed.
  """
  alias Ryker.ControlPlane.SettingsSections
  alias Ryker.Credentials
  alias Ryker.Settings
  alias Ryker.Webhooks

  @type result :: {:ok, Settings.snapshot()} | {:error, term()}

  @spec initialize(String.t()) :: result()
  def initialize(actor_ref), do: Settings.initialize(actor_ref)

  @doc "Saves one singleton or retention section at an expected revision."
  @spec save(atom() | String.t(), map(), integer(), String.t()) :: result()
  def save(section_key, params, expected_revision, actor_ref) when is_map(params) do
    with {:ok, section} <- section(section_key),
         {:ok, attributes} <- SettingsSections.cast(section, params) do
      write(section, attributes, expected_revision, params, actor_ref)
    end
  end

  @doc "Estimates what a proposed retention change would newly expose to cleanup."
  @spec preview_retention(map(), integer()) :: {:ok, map()} | {:error, term()}
  def preview_retention(params, expected_revision) when is_map(params) do
    with {:ok, section} <- section(:retention),
         {:ok, attributes} <- SettingsSections.cast(section, params) do
      Settings.preview_retention(attributes, expected_revision)
    end
  end

  @doc "Creates or updates one row of a collection section."
  @spec put_item(atom() | String.t(), map(), integer(), String.t()) :: result()
  def put_item(section_key, params, expected_revision, actor_ref) when is_map(params) do
    with {:ok, section} <- section(section_key),
         {:ok, attributes} <- SettingsSections.cast(section, params) do
      put(section, identify(section, attributes, params), expected_revision, actor_ref)
    end
  end

  @doc """
  Checks one saved webhook source against a sample payload and reports what it maps to.

  Reading only: the preview records no input, opens no incident, submits no
  model work and sends nothing. It exists so a mapping is proven before an
  incident depends on it.
  """
  @spec preview_webhook(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def preview_webhook(name, body) when is_binary(name) and is_binary(body) do
    with {:ok, snapshot} <- Settings.fetch() do
      case Enum.find(snapshot.webhook_sources, &(&1.name == name)) do
        nil -> {:error, :unknown_webhook_source}
        source -> Webhooks.Preview.check(source, body)
      end
    end
  end

  @doc "Removes one row of a collection section."
  @spec delete_item(atom() | String.t(), String.t(), integer(), String.t()) :: result()
  def delete_item(section_key, item_key, expected_revision, actor_ref)
      when is_binary(item_key) do
    with {:ok, section} <- section(section_key),
         do: remove(section, item_key, expected_revision, actor_ref)
  end

  defp section(key) do
    case SettingsSections.fetch(key) do
      {:ok, section} -> {:ok, section}
      :error -> {:error, {:invalid_settings, [{:section, :unknown}]}}
    end
  end

  # A generated identifier is not an editable field, so the form carries the row
  # it is editing separately. Without it every save would create a new row.
  defp identify(section, attributes, params) do
    case Map.get(params, "item_key") do
      key when is_binary(key) and key != "" -> Map.put(attributes, section.item_key, key)
      _new_row -> attributes
    end
  end

  defp write(%{kind: :retention}, attributes, revision, params, actor_ref) do
    Settings.save_retention(attributes, revision, actor_ref, Map.get(params, "confirmation"))
  end

  defp write(%{domain: :slack}, attributes, revision, _params, actor_ref),
    do: Settings.save_slack(attributes, revision, actor_ref)

  defp write(%{domain: :publication}, attributes, revision, _params, actor_ref),
    do: Settings.save_publication(attributes, revision, actor_ref)

  defp write(%{domain: :report}, attributes, revision, _params, actor_ref),
    do: Settings.save_report(attributes, revision, actor_ref)

  defp write(%{domain: :learning}, attributes, revision, _params, actor_ref),
    do: Settings.save_learning(attributes, revision, actor_ref)

  defp write(%{domain: :work}, attributes, revision, _params, actor_ref),
    do: Settings.save_work(attributes, revision, actor_ref)

  defp put(%{key: :pricing}, attributes, revision, actor_ref),
    do: Settings.put_pricing_rate(attributes, revision, actor_ref)

  # A source may reference only a credential this deployment registered. Saving
  # an unregistered name would leave a route that cannot start, and accepting an
  # arbitrary name would make the form a way to read the process environment.
  # A source with no credential chosen is refused by the settings, beside
  # whatever else it is missing, so the form can say everything at once.
  defp put(%{key: :webhooks}, attributes, revision, actor_ref) do
    case Map.get(attributes, :secret_name) do
      nil ->
        Settings.put_webhook_source(attributes, revision, actor_ref)

      name ->
        if name in registered_secrets(),
          do: Settings.put_webhook_source(attributes, revision, actor_ref),
          else: {:error, {:invalid_settings, [{:secret_name, :unregistered_secret}]}}
    end
  end

  defp remove(%{key: :pricing}, id, revision, actor_ref),
    do: Settings.delete_pricing_rate(id, revision, actor_ref)

  defp remove(%{key: :webhooks}, name, revision, actor_ref),
    do: Settings.delete_webhook_source(name, revision, actor_ref)

  defp registered_secrets do
    Credentials.statuses()
    |> Enum.filter(&(&1.kind == :webhook))
    |> Enum.map(& &1.name)
  end
end
