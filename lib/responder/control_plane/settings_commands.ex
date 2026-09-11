defmodule Responder.ControlPlane.SettingsCommands do
  @moduledoc """
  The loopback operator's writes into durable product settings.

  Each command names a section from the catalog, casts its form into typed
  attributes and hands them to `Responder.Settings`, which owns authorization,
  the expected revision, whole-changeset validation and the edit receipt.
  Nothing here writes a row or decides what is allowed.
  """

  alias Responder.ControlPlane.SettingsSections
  alias Responder.Settings

  @type result :: {:ok, Settings.snapshot()} | {:error, term()}

  @spec initialize() :: result()
  def initialize, do: Settings.initialize(Settings.actor())

  @doc "Saves one singleton or retention section at an expected revision."
  @spec save(atom() | String.t(), map(), integer()) :: result()
  def save(section_key, params, expected_revision) when is_map(params) do
    with {:ok, section} <- section(section_key),
         {:ok, attributes} <- SettingsSections.cast(section, params) do
      write(section, attributes, expected_revision, params)
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
  @spec put_item(atom() | String.t(), map(), integer()) :: result()
  def put_item(section_key, params, expected_revision) when is_map(params) do
    with {:ok, section} <- section(section_key),
         {:ok, attributes} <- SettingsSections.cast(section, params) do
      put(section, identify(section, attributes, params), expected_revision)
    end
  end

  @doc "Removes one row of a collection section."
  @spec delete_item(atom() | String.t(), String.t(), integer()) :: result()
  def delete_item(section_key, item_key, expected_revision) when is_binary(item_key) do
    with {:ok, section} <- section(section_key), do: remove(section, item_key, expected_revision)
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

  defp write(%{kind: :retention}, attributes, revision, params) do
    Settings.save_retention(attributes, revision, actor(), Map.get(params, "confirmation"))
  end

  defp write(%{domain: :slack}, attributes, revision, _params),
    do: Settings.save_slack(attributes, revision, actor())

  defp write(%{domain: :github}, attributes, revision, _params),
    do: Settings.save_github(attributes, revision, actor())

  defp write(%{domain: :publication}, attributes, revision, _params),
    do: Settings.save_publication(attributes, revision, actor())

  defp write(%{domain: :emisar}, attributes, revision, _params),
    do: Settings.save_emisar(attributes, revision, actor())

  defp write(%{domain: :report}, attributes, revision, _params),
    do: Settings.save_report(attributes, revision, actor())

  defp write(%{domain: :learning}, attributes, revision, _params),
    do: Settings.save_learning(attributes, revision, actor())

  defp write(%{domain: :work}, attributes, revision, _params),
    do: Settings.save_work(attributes, revision, actor())

  defp put(%{key: :pricing}, attributes, revision),
    do: Settings.put_pricing_rate(attributes, revision, actor())

  defp remove(%{key: :pricing}, id, revision),
    do: Settings.delete_pricing_rate(id, revision, actor())

  defp actor, do: Settings.actor()
end
