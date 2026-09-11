defmodule Responder.Settings.Validation do
  @moduledoc "Shared typed validation for settings writes; errors name fields, never values."

  import Ecto.Changeset

  @ten_years 10 * 365 * 86_400
  @retention_fields ~w(operational_data_seconds conversation_memory_seconds closed_work_seconds episode_history_seconds audit_data_seconds)a
  @reference ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @slack_id ~r/\A[A-Z0-9]{1,255}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @secret_name ~r/\A[A-Z][A-Z0-9_]{0,127}\z/
  @adapter_name ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @github_repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @email ~r/\A[^\s@]+@[^\s@]+\z/

  def reference_pattern, do: @reference
  def slack_id_pattern, do: @slack_id
  def hex64_pattern, do: @hex64
  def secret_name_pattern, do: @secret_name
  def adapter_name_pattern, do: @adapter_name
  def github_repository_pattern, do: @github_repository
  def email_pattern, do: @email

  @doc "Normalizes atom or string keys onto the allowed fields; unknown keys are refused."
  def attributes(attributes, allowed) when is_map(attributes) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn {key, value}, {:ok, found} ->
      case field(key, allowed) do
        {:ok, field} -> {:cont, {:ok, Map.put(found, field, value)}}
        :error -> {:halt, {:error, {:invalid_settings, [{safe_key(key), :unknown}]}}}
      end
    end)
  end

  def attributes(_attributes, _allowed), do: {:error, {:invalid_settings, [{:attributes, :map}]}}

  defp field(key, allowed) when is_atom(key) do
    if key in allowed, do: {:ok, key}, else: :error
  end

  defp field(key, allowed) when is_binary(key) do
    case Enum.find(allowed, &(Atom.to_string(&1) == key)) do
      nil -> :error
      field -> {:ok, field}
    end
  end

  defp field(_key, _allowed), do: :error

  defp safe_key(key) when is_atom(key), do: key
  defp safe_key(key) when is_binary(key) and byte_size(key) <= 64, do: key
  defp safe_key(_key), do: :unknown

  @doc "Casts already-normalized attributes with schemaless types."
  def cast_values(attributes, types) do
    changeset = cast({%{}, types}, attributes, Map.keys(types))

    if changeset.valid?,
      do: {:ok, changeset.changes},
      else: {:error, {:invalid_settings, errors(changeset)}}
  end

  def retention(proposed) do
    types = Map.new(@retention_fields, &{&1, :integer})

    case cast_values(proposed, types) do
      {:ok, values} -> bounded_horizons(values)
      {:error, {:invalid_settings, errors}} -> {:error, errors}
    end
  end

  defp bounded_horizons(values) do
    out_of_bounds =
      Enum.flat_map(values, fn {field, value} ->
        if value < 60 or value > @ten_years, do: [{field, :bounds}], else: []
      end)

    cond do
      Map.keys(values) |> Enum.sort() != Enum.sort(@retention_fields) ->
        {:error, [{:retention, :incomplete}]}

      out_of_bounds != [] ->
        {:error, out_of_bounds}

      not ordered?(values) ->
        {:error, [{:retention, :ordering}]}

      true ->
        {:ok, values}
    end
  end

  defp ordered?(values) do
    values.operational_data_seconds <= values.closed_work_seconds and
      values.closed_work_seconds <= values.episode_history_seconds and
      values.episode_history_seconds <= values.audit_data_seconds and
      values.operational_data_seconds <= values.conversation_memory_seconds
  end

  def revision(value) when is_integer(value) and value >= 0, do: :ok
  def revision(_value), do: {:error, {:invalid_settings, [{:revision, :integer}]}}

  def host_ref(value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..128 and String.trim(value) == value and
         value != "" and not String.contains?(value, [<<0>>, "\n", "\r"]),
       do: :ok,
       else: {:error, {:invalid_settings, [{:host_ref, :format}]}}
  end

  def host_ref(_value), do: {:error, {:invalid_settings, [{:host_ref, :format}]}}

  @doc "Field/reason pairs only; messages carry no submitted values."
  def errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {_message, options}} ->
      {field, Keyword.get(options, :validation, :invalid)}
    end)
    |> Enum.uniq()
  end

  def validate_reference(changeset, field) do
    validate_format(changeset, field, @reference)
  end

  def validate_slack_ids(changeset, field) do
    validate_change(changeset, field, fn ^field, values ->
      if is_list(values) and Enum.uniq(values) == values and
           Enum.all?(values, &(is_binary(&1) and Regex.match?(@slack_id, &1))),
         do: [],
         else: [{field, {"must list unique Slack IDs", validation: :slack_ids}}]
    end)
  end

  def validate_unique_list(changeset, field, predicate) do
    validate_change(changeset, field, fn ^field, values ->
      if is_list(values) and Enum.uniq(values) == values and Enum.all?(values, predicate),
        do: [],
        else: [{field, {"must be a unique list", validation: :list}}]
    end)
  end

  def validate_git_ref(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      invalid =
        byte_size(value) > 240 or String.starts_with?(value, ["-", "/"]) or
          String.ends_with?(value, ["/", "."]) or
          String.contains?(value, ["..", "@{", " ", "~", "^", ":", "?", "*", "[", "\\"]) or
          String.trim(value) == ""

      if invalid, do: [{field, {"must be a safe Git ref", validation: :git_ref}}], else: []
    end)
  end

  def validate_absolute_path(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if Path.type(value) == :absolute and not String.contains?(value, [<<0>>, "\n"]),
        do: [],
        else: [{field, {"must be an absolute path", validation: :absolute_path}}]
    end)
  end

  def validate_known(changeset, field, known, reason) do
    validate_change(changeset, field, fn ^field, value ->
      if value in known, do: [], else: [{field, {"is unknown", validation: reason}}]
    end)
  end
end
