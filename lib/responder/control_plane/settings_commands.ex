defmodule Responder.ControlPlane.SettingsCommands do
  @moduledoc """
  The loopback operator's writes into durable product settings.

  Each command names a section from the catalog, casts its form into typed
  attributes and hands them to `Responder.Settings`, which owns authorization,
  the expected revision, whole-changeset validation and the edit receipt.
  Nothing here writes a row or decides what is allowed.
  """

  alias Responder.Bootstrap
  alias Responder.ControlPlane.SettingsSections
  alias Responder.Settings
  alias Responder.Settings.WorkerPolicies
  alias Responder.Webhooks.Preview

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
        source -> Preview.check(source, body)
      end
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

  defp put(%{key: :repositories}, attributes, revision),
    do: Settings.put_repository(attributes, revision, actor())

  defp put(%{key: :contexts}, attributes, revision),
    do: Settings.put_repository_context(attributes, revision, actor())

  defp put(%{key: :github_bindings}, attributes, revision),
    do: Settings.put_github_binding(attributes, revision, actor())

  # A source may reference only a credential this deployment registered. Saving
  # an unregistered name would leave a route that cannot start, and accepting an
  # arbitrary name would make the form a way to read the process environment.
  defp put(%{key: :webhooks}, attributes, revision) do
    if Map.get(attributes, :secret_name) in registered_secrets() do
      Settings.put_webhook_source(attributes, revision, actor())
    else
      {:error, {:invalid_settings, [{:secret_name, :unregistered_secret}]}}
    end
  end

  # The form chooses a policy by name; the digest and authority come from the
  # worker advertisement, so a browser can neither invent a pin nor keep one
  # the fleet has stopped offering.
  defp put(%{key: :policies}, attributes, revision) do
    case WorkerPolicies.resolve(attributes, workspace_ref()) do
      {:ok, verified} -> Settings.put_policy_binding(verified, revision, actor())
      {:error, reason} -> {:error, {:invalid_settings, [{:policy_name, reason}]}}
    end
  end

  defp remove(%{key: :pricing}, id, revision),
    do: Settings.delete_pricing_rate(id, revision, actor())

  defp remove(%{key: :repositories}, ref, revision),
    do: Settings.delete_repository(ref, revision, actor())

  defp remove(%{key: :contexts}, ref, revision),
    do: Settings.delete_repository_context(ref, revision, actor())

  defp remove(%{key: :github_bindings}, name, revision),
    do: Settings.delete_github_binding(name, revision, actor())

  defp remove(%{key: :policies}, id, revision),
    do: Settings.delete_policy_binding(id, revision, actor())

  defp remove(%{key: :webhooks}, name, revision),
    do: Settings.delete_webhook_source(name, revision, actor())

  defp registered_secrets do
    case Bootstrap.registered_webhook_secret_names() do
      {:ok, names} -> names
      :error -> []
    end
  end

  defp workspace_ref do
    case Settings.fetch() do
      {:ok, snapshot} -> snapshot.work.workspace_ref
      {:error, _reason} -> nil
    end
  end

  defp actor, do: Settings.actor()
end
