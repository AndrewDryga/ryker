defmodule Ryker.Settings.Validation do
  @moduledoc "Shared typed validation for settings writes; errors name fields, never values."
  import Ecto.Changeset
  alias Ryker.Maps
  alias Ryker.Settings.Retention
  alias Ryker.Slack

  @ten_years 10 * 365 * 86_400
  # Every retention limit, in seconds, then whether routing and work examples
  # are kept at all. The example limits are bounded like the others but ordered
  # against none: an example is a copy and outlives what it was copied from.
  @retention_limits ~w(operational_data_seconds conversation_memory_seconds closed_work_seconds episode_history_seconds audit_data_seconds routing_examples_seconds work_examples_seconds)a
  @retention_types Map.new(@retention_limits, &{&1, :integer})
                   |> Map.put(:routing_examples_enabled, :boolean)
                   |> Map.put(:work_examples_enabled, :boolean)
  @retention_fields Map.keys(@retention_types)
  @reference ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @secret_name ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/
  @adapter_name ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  def secret_name_pattern, do: @secret_name
  def adapter_name_pattern, do: @adapter_name

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

  # Casts already-normalized attributes with schemaless types.
  defp cast_values(attributes, types) do
    changeset = cast({%{}, types}, attributes, Map.keys(types))

    if changeset.valid?,
      do: {:ok, changeset.changes},
      else: {:error, {:invalid_settings, errors(changeset)}}
  end

  def retention(proposed) do
    case cast_values(proposed, @retention_types) do
      {:ok, values} -> bounded_horizons(values)
      {:error, {:invalid_settings, errors}} -> {:error, errors}
    end
  end

  defp bounded_horizons(values) do
    out_of_bounds =
      values
      |> Map.take(@retention_limits)
      |> Enum.flat_map(fn {field, value} ->
        if value < 60 or value > @ten_years, do: [{field, :bounds}], else: []
      end)

    cond do
      not Maps.exact_keys?(values, @retention_fields) ->
        {:error, [{:retention, :incomplete}]}

      out_of_bounds != [] ->
        {:error, out_of_bounds}

      not Retention.ordered?(values) ->
        {:error, [{:retention, :ordering}]}

      true ->
        {:ok, values}
    end
  end

  def revision(value) when is_integer(value) and value >= 0, do: :ok
  def revision(_value), do: {:error, {:invalid_settings, [{:revision, :integer}]}}

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
           Enum.all?(values, &Slack.Id.valid?/1),
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

  # Git's own rule for a branch name (`git check-ref-format --branch`): a
  # name it refuses saved here and then failed every push made with it.
  def validate_git_ref(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if git_ref?(value),
        do: [],
        else: [{field, {"must be a safe Git ref", validation: :git_ref}}]
    end)
  end

  defp git_ref?(value) do
    byte_size(value) in 1..240 and value != "@" and
      not String.starts_with?(value, ["-", "/"]) and
      not String.ends_with?(value, ["/", "."]) and
      not String.contains?(value, ["..", "//", "@{", " ", "~", "^", ":", "?", "*", "[", "\\"]) and
      not Regex.match?(~r/[\x00-\x1f\x7f]/, value) and
      value
      |> String.split("/")
      |> Enum.all?(&(not String.starts_with?(&1, ".") and not String.ends_with?(&1, ".lock")))
  end

  def validate_known(changeset, field, known, reason) do
    validate_change(changeset, field, fn ^field, value ->
      if value in known, do: [], else: [{field, {"is unknown", validation: reason}}]
    end)
  end
end
