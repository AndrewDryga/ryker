defmodule Ryker.Flywheel.Protocol do
  @moduledoc "Bounded operator documents; source content is evidence, never instructions or authority."
  alias Ryker.{CanonicalJSON, Maps, Reference, Repo, UTCDateTime}

  @proposal_fields ~w(title example benefit tradeoffs change verification baseline user_action confidence priority)
  @kinds ~w(code prompt settings tools user_action investigation)

  def kinds, do: @kinds

  def datetime(value) do
    case UTCDateTime.parse(value) do
      {:ok, at} -> {:ok, UTCDateTime.to_usec(at)}
      :error -> {:error, :invalid_utc_time}
    end
  end

  @doc "Internal — parses a required time inside run/finding transactions, rolling back invalid input."
  def datetime!(value) do
    case datetime(value) do
      {:ok, at} -> at
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def identity?(%{"source" => source, "ref" => ref, "version" => version} = identity) do
    Maps.exact_keys?(identity, ~w(source ref version)) and
      Reference.valid?(source, 120) and Reference.valid?(ref, 512) and
      Reference.valid?(version, 256)
  end

  def identity?(_identity), do: false

  def finding?(
        %{
          "key" => key,
          "owner" => owner,
          "kind" => kind,
          "proposal" => proposal,
          "evidence" => evidence
        } = finding
      ) do
    Maps.exact_keys?(finding, ~w(key owner kind proposal evidence)) and
      Reference.valid?(key, 120) and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, key) and
      owner in ~w(ryker user both) and kind in @kinds and proposal?(proposal, owner) and
      is_list(evidence) and length(evidence) in 1..100 and Enum.all?(evidence, &identity?/1)
  end

  def finding?(_finding), do: false

  defp proposal?(proposal, owner) when is_map(proposal) do
    Maps.exact_keys?(proposal, @proposal_fields) and
      Enum.all?(
        ~w(title example benefit tradeoffs change verification baseline),
        &Reference.valid?(proposal[&1], 2_000)
      ) and
      proposal["confidence"] in ~w(high medium low) and
      proposal["priority"] in ~w(high medium low) and
      user_action?(proposal["user_action"], owner)
  end

  defp proposal?(_proposal, _owner), do: false
  defp user_action?(nil, "ryker"), do: true
  defp user_action?(value, owner) when owner in ~w(user both), do: Reference.valid?(value, 2_000)
  defp user_action?(_value, _owner), do: false

  def policy?(
        %{
          "max_tasks" => tasks,
          "max_cost_usd" => cost,
          "allowed_kinds" => kinds
        } = policy
      ) do
    Maps.exact_keys?(policy, ~w(max_tasks max_cost_usd allowed_kinds)) and
      integer_between?(tasks, 1, 100) and money?(cost) and
      is_list(kinds) and kinds != [] and Enum.all?(kinds, &(&1 in @kinds))
  end

  def policy?(_policy), do: false

  def page?(
        %{
          "records" => records,
          "cursor" => cursor,
          "next_cursor" => next_cursor,
          "complete" => complete,
          "query" => query
        } = page
      ) do
    Maps.only_keys?(page, ~w(records cursor next_cursor complete query coverage limitation)) and
      coverage?(page) and
      records?(records) and
      cursor?(cursor) and cursor?(next_cursor) and is_boolean(complete) and
      Reference.valid?(query, 2_000) and
      page_end?(complete, cursor, next_cursor)
  end

  def page?(_page), do: false

  defp coverage?(%{"coverage" => status, "limitation" => reason})
       when status in ~w(partial unavailable expired),
       do: Reference.valid?(reason, 2_000)

  defp coverage?(page) do
    Map.get(page, "coverage", "complete") == "complete" and
      (is_nil(page["limitation"]) or Reference.valid?(page["limitation"], 2_000))
  end

  defp integer_between?(value, low, high),
    do: is_integer(value) and value >= low and value <= high

  defp money?(cost) do
    is_binary(cost) and Regex.match?(~r/^[0-9]{1,5}(\.[0-9]{1,2})?$/, cost) and
      Decimal.compare(Decimal.new(cost), Decimal.new(0)) == :gt
  end

  defp records?(records) do
    is_list(records) and length(records) <= 100 and Enum.all?(records, &record?/1) and
      length(Enum.uniq_by(records, &{&1["ref"], &1["version"]})) == length(records)
  end

  defp page_end?(true, _cursor, nil), do: true

  defp page_end?(false, cursor, next_cursor),
    do: not is_nil(next_cursor) and next_cursor != cursor

  defp page_end?(_complete, _cursor, _next_cursor), do: false

  defp cursor?(nil), do: true
  defp cursor?(cursor), do: Reference.valid?(cursor, 4_096)

  defp record?(%{"ref" => ref, "version" => version, "data" => data} = record) do
    Maps.exact_keys?(record, ~w(ref version data)) and Reference.valid?(ref, 512) and
      Reference.valid?(version, 256) and
      is_map(data) and byte_size(Jason.encode!(data)) <= 65_536
  end

  defp record?(_record), do: false

  def identities(source, records),
    do: Enum.map(records, &%{"source" => source, "ref" => &1["ref"], "version" => &1["version"]})

  def digest(value), do: CanonicalJSON.digest(value)

  def document(%Ecto.Association.NotLoaded{}), do: nil
  def document(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def document(%Decimal{} = decimal), do: Decimal.to_string(decimal)

  def document(%_{} = value),
    do: value |> Map.from_struct() |> Map.delete(:__meta__) |> document()

  def document(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), document(item)} end)

  def document(value) when is_list(value), do: Enum.map(value, &document/1)
  def document(value) when value in [nil, true, false], do: value
  def document(value) when is_atom(value), do: Atom.to_string(value)
  def document(value), do: value
end
