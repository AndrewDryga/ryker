defmodule Ryker.State.ScheduleRuntime do
  @moduledoc false

  alias Ryker.Reference
  alias Ryker.State.ScheduleWorker

  @fields [
    :governed_operation_policy,
    :lease_seconds,
    :misfire_grace_seconds,
    :poll_interval_ms,
    :read_only_policy,
    :repositories,
    :retry_base_seconds,
    :retry_max_seconds,
    :worker_ref
  ]

  @required [:governed_operation_policy, :read_only_policy, :repositories, :worker_ref]

  def child_spec(configuration) do
    options = options!(configuration)

    %{
      id: __MODULE__,
      start:
        {ScheduleWorker, :start_link,
         [
           [
             dispatcher_options: options.dispatcher_options,
             poll_interval_ms: options.poll_interval_ms
           ]
         ]},
      type: :worker
    }
  end

  def options!(configuration) do
    configuration = normalize!(configuration)
    read_only = policy!(Map.fetch!(configuration, :read_only_policy), :read_only_policy)

    governed =
      policy!(Map.fetch!(configuration, :governed_operation_policy), :governed_operation_policy)

    repositories = repositories!(Map.fetch!(configuration, :repositories))
    worker_ref = Map.fetch!(configuration, :worker_ref)
    validate_ref!(worker_ref, :worker_ref)

    lease_seconds = integer!(configuration, :lease_seconds, 60, 1, 86_400)
    poll_interval_ms = integer!(configuration, :poll_interval_ms, 1_000, 1, 300_000)
    grace = integer!(configuration, :misfire_grace_seconds, 900, 0, 31_536_000)
    retry_base = integer!(configuration, :retry_base_seconds, 5, 1, 86_400)
    retry_max = integer!(configuration, :retry_max_seconds, 1_800, retry_base, 86_400)

    resolver = fn
      %{authority: :read_only} ->
        {:ok, read_only}

      %{authority: :governed_operation} ->
        {:ok, governed}

      %{authority: :repository_write, repository: repository} ->
        Map.fetch(repositories, repository)

      _schedule ->
        {:error, :schedule_policy_unavailable}
    end

    %{
      dispatcher_options: [
        lease_seconds: lease_seconds,
        misfire_grace_seconds: grace,
        policy_resolver: resolver,
        retry_base_seconds: retry_base,
        retry_max_seconds: retry_max,
        worker_ref: worker_ref
      ],
      poll_interval_ms: poll_interval_ms
    }
  end

  defp normalize!(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration) and
         Enum.uniq(Keyword.keys(configuration)) == Keyword.keys(configuration),
       do: configuration |> Map.new() |> normalize!(),
       else: raise(ArgumentError, "schedule configuration must use unique known fields")
  end

  defp normalize!(%{} = configuration) do
    if Map.keys(configuration) -- @fields == [] and
         Enum.all?(@required, &Map.has_key?(configuration, &1)),
       do: configuration,
       else: raise(ArgumentError, "schedule configuration has missing or unknown fields")
  end

  defp normalize!(_configuration),
    do: raise(ArgumentError, "schedule configuration must be a map or keyword list")

  defp repositories!(repositories) when is_map(repositories) do
    Map.new(repositories, fn {repository, policy} ->
      validate_ref!(repository, :repository)
      {repository, policy!(policy, :repository_policy)}
    end)
  end

  defp repositories!(_repositories),
    do: raise(ArgumentError, "schedule repositories must be a map")

  defp policy!(%{digest: digest, name: name}, field) do
    validate_ref!(name, field)

    if is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: %{digest: digest, name: name},
      else: raise(ArgumentError, "schedule #{field} must contain a SHA-256 digest")
  end

  defp policy!(_policy, field),
    do: raise(ArgumentError, "schedule #{field} must contain name and digest")

  defp integer!(configuration, field, default, minimum, maximum) do
    value = Map.get(configuration, field, default)

    if is_integer(value) and value in minimum..maximum,
      do: value,
      else: raise(ArgumentError, "schedule #{field} is outside its safe bound")
  end

  defp validate_ref!(value, field) do
    unless Reference.valid?(value),
      do: raise(ArgumentError, "schedule #{field} must be a bounded nonblank string")
  end
end
