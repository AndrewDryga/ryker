defmodule Ryker.Credentials.LegacyImporter do
  @moduledoc "Explicit, conflict-safe import from the retired integration environment contract."

  alias Ryker.{Credentials, Settings}

  @actor "migration:legacy-environment"
  @fixed [
    {:slack_app, "primary", "SLACK_APP_TOKEN"},
    {:slack_bot, "primary", "SLACK_BOT_TOKEN"},
    {:github_private_key, "primary", "GITHUB_APP_PRIVATE_KEY"},
    {:github_webhook, "primary", "GITHUB_WEBHOOK_SECRET"}
  ]

  @spec run((String.t() -> {:ok, String.t()} | :error)) :: {:ok, map()} | {:error, term()}
  def run(env \\ &System.fetch_env/1) do
    entries = @fixed ++ webhook_entries(env)

    result =
      Enum.reduce(entries, %{imported: [], present: [], conflicts: [], invalid: []}, fn
        {kind, name, environment_name}, totals ->
          import_one(kind, name, environment_name, env, totals)
      end)

    import_settings(env, result)
  end

  defp import_one(kind, name, environment_name, env, totals) do
    case env.(environment_name) do
      :error ->
        totals

      {:ok, value} when is_binary(value) and value != "" ->
        fingerprint = digest(value)

        case Credentials.status(kind, name) do
          %{status: :missing} ->
            import_missing(kind, name, value, environment_name, totals)

          %{fingerprint: ^fingerprint} ->
            update_in(totals.present, &[environment_name | &1])

          %{status: :configured} ->
            update_in(totals.conflicts, &[environment_name | &1])
        end

      {:ok, _invalid} ->
        update_in(totals.invalid, &[%{name: environment_name, reason: :invalid_value} | &1])
    end
  end

  defp import_missing(kind, name, value, environment_name, totals) do
    with {:ok, _metadata} <- Credentials.put(kind, name, value, @actor),
         {:ok, _metadata} <- Credentials.verify(kind, name, :verified, @actor) do
      update_in(totals.imported, &[environment_name | &1])
    else
      {:error, reason} ->
        update_in(totals.invalid, &[%{name: environment_name, reason: reason} | &1])
    end
  end

  defp import_settings(env, result) do
    with {:ok, snapshot} <- Settings.fetch() do
      {result, snapshot} = import_github_app_id(env, result, snapshot)
      {result, _snapshot} = import_github_api_url(env, result, snapshot)
      result = require_verified_emisar_reconnect(env, result)
      {:ok, normalize(result)}
    end
  end

  defp import_github_app_id(env, result, snapshot) do
    case env.("GITHUB_APP_ID") do
      {:ok, value} ->
        case Integer.parse(value) do
          {id, ""} when id > 0 and snapshot.github.app_id == id ->
            {update_in(result.present, &["GITHUB_APP_ID" | &1]), snapshot}

          {id, ""} when id > 0 and is_nil(snapshot.github.app_id) ->
            save_github(snapshot, %{app_id: id}, result, "GITHUB_APP_ID")

          {id, ""} when id > 0 ->
            {update_in(result.conflicts, &["GITHUB_APP_ID" | &1]), snapshot}

          _invalid ->
            {update_in(result.invalid, &[%{name: "GITHUB_APP_ID", reason: :invalid_value} | &1]),
             snapshot}
        end

      :error ->
        {result, snapshot}
    end
  end

  defp import_github_api_url(env, result, snapshot) do
    import_endpoint(
      env,
      "GITHUB_API_URL",
      snapshot.github.api_url,
      "https://api.github.com",
      fn value ->
        save_github(snapshot, %{api_url: value}, result, "GITHUB_API_URL")
      end,
      result,
      snapshot
    )
  end

  defp require_verified_emisar_reconnect(env, result) do
    if match?({:ok, _}, env.("EMISAR_API_TOKEN")) or match?({:ok, _}, env.("EMISAR_RPC_URL")) do
      update_in(
        result.invalid,
        &[
          %{name: "EMISAR_API_TOKEN", reason: :verified_account_reconnect_required} | &1
        ]
      )
    else
      result
    end
  end

  defp import_endpoint(env, name, current, default, save, result, snapshot) do
    case env.(name) do
      {:ok, value} when current == value ->
        {update_in(result.present, &[name | &1]), snapshot}

      {:ok, value} when current == default ->
        save.(value)

      {:ok, _value} ->
        {update_in(result.conflicts, &[name | &1]), snapshot}

      :error ->
        {result, snapshot}
    end
  end

  defp save_github(snapshot, attributes, result, name) do
    case Settings.save_github(attributes, snapshot.installation.revision, @actor) do
      {:ok, updated} ->
        {update_in(result.imported, &[name | &1]), updated}

      {:error, reason} ->
        {update_in(result.invalid, &[%{name: name, reason: reason} | &1]), snapshot}
    end
  end

  defp webhook_entries(env) do
    case env.("RYKER_WEBHOOK_SECRET_NAMES") do
      {:ok, names} ->
        names
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn environment_name ->
          {:webhook, webhook_name(environment_name), environment_name}
        end)

      :error ->
        []
    end
  end

  defp webhook_name(environment_name) do
    environment_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.:-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 128)
  end

  defp normalize(result) do
    %{
      imported: Enum.sort(result.imported),
      present: Enum.sort(result.present),
      conflicts: Enum.sort(result.conflicts),
      invalid: Enum.sort_by(result.invalid, & &1.name)
    }
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
