defmodule Ryker.TrainingExamples do
  @moduledoc """
  What routing and Work examples share (`Ryker.RoutingExamples`,
  `Ryker.WorkExamples`): a copy that one bad row
  cannot stop, whether a copy kept an example or only its identity, the
  feedback copied beside an example, an example's usage, erasing one, and the
  stream an export writes. Each kind keeps what only it knows: what it copies,
  from where, and what its line holds. The two had drifting copies of all of
  this (2026-10-04 review).
  """

  require Logger
  alias Ryker.Accounting.Pricing
  alias Ryker.{Repo, RoutingExamples}

  @token_kinds ~w(input_tokens cached_input_tokens output_tokens reasoning_tokens)

  # A copy that failed this many times is passed over, and at most this many
  # failures are remembered.
  @failure_attempts 3
  @remembered_failures 1_000

  @doc """
  Runs one copy. One that raises is logged by kind only, since the exception
  can carry what it copied, and answers `{:error, :copy_failed}`; it never
  stops the copies after it. Only losing the database stops a pass, for the
  worker's backoff.
  """
  @spec copy(String.t(), String.t(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def copy(kind, id, copy) do
    copy.()
  rescue
    error in DBConnection.ConnectionError ->
      reraise error, __STACKTRACE__

    error ->
      Logger.error("#{kind} copy failed #{id} category=#{inspect(error.__struct__)}")
      {:error, :copy_failed}
  end

  @doc """
  Inserts a copied example once: `:copied` when it is kept whole, `:forgotten`
  when a person's forgetting left it its identity only.
  """
  @spec insert!(struct(), [atom()]) :: :copied | :forgotten
  def insert!(example, conflict_target) do
    Repo.insert!(example, on_conflict: :nothing, conflict_target: conflict_target)
    if is_nil(example.forgotten_at), do: :copied, else: :forgotten
  end

  @doc """
  What a pass's copies, each `{id, result}`, came to: how many kept an
  example whole, how many its identity only, and the ids whose copy failed.
  """
  @spec counts([{Ecto.UUID.t(), {:ok, term()} | {:error, term()}}]) :: %{
          copied: non_neg_integer(),
          forgotten: non_neg_integer(),
          failed: [Ecto.UUID.t()]
        }
  def counts(results) do
    %{
      copied: Enum.count(results, &match?({_id, {:ok, :copied}}, &1)),
      forgotten: Enum.count(results, &match?({_id, {:ok, :forgotten}}, &1)),
      failed: for({id, {:error, :copy_failed}} <- results, do: id)
    }
  end

  @doc """
  A worker's memory of failed copies, `%{id => attempts}`, with a pass's
  `failed` counted in. Copies are taken oldest first, so a batch of rows
  failing every time held back everything settled after them for the whole
  window, a year by default (2026-10-04 review).
  """
  @spec failures(%{optional(Ecto.UUID.t()) => pos_integer()}, [Ecto.UUID.t()]) ::
          %{optional(Ecto.UUID.t()) => pos_integer()}
  def failures(remembered, failed) do
    Enum.reduce(failed, remembered, fn id, remembered ->
      if Map.has_key?(remembered, id) or map_size(remembered) < @remembered_failures,
        do: Map.update(remembered, id, 1, &(&1 + 1)),
        else: remembered
    end)
  end

  @doc "The ids a worker passes over: copies that failed #{@failure_attempts} times."
  @spec passed_over(%{optional(Ecto.UUID.t()) => pos_integer()}) :: [Ecto.UUID.t()]
  def passed_over(remembered),
    do: for({id, attempts} <- remembered, attempts >= @failure_attempts, do: id)

  @doc """
  Copies each new signal of `signals` into `feedback` once, while `enabled?`
  holds, under the lock a copy holds, so a forgetting either committed first
  or waits and removes what this copied. Returns how many it copied.
  """
  @spec copy_feedback((-> boolean()), module(), Ecto.Queryable.t()) :: {:ok, non_neg_integer()}
  def copy_feedback(enabled?, feedback, signals) do
    Repo.transaction(fn ->
      if enabled?.() do
        :ok = RoutingExamples.copy_lock_in_transaction()

        {count, _rows} =
          Repo.insert_all(feedback, signals,
            on_conflict: :nothing,
            conflict_target: [:example_id, :signal_id]
          )

        count
      else
        0
      end
    end)
  end

  @doc """
  An example's usage: the four token counts, each nil when none were
  recorded; the provider's cost when it reported one, otherwise an estimate at
  the price saved for `target` on the day of `at`, as Usage shows it; and
  `timings` as given.
  """
  @spec usage(map() | nil, String.t() | nil, String.t() | nil, DateTime.t(), map()) :: map()
  def usage(tokens, cost, target, at, timings) do
    counts = Map.new(@token_kinds, &{&1, tokens && tokens[&1]})
    estimated = if is_map(tokens) and is_nil(cost), do: estimate(counts, target, at)

    counts
    |> Map.merge(%{"cost_usd" => cost, "estimated_cost_usd" => estimated})
    |> Map.merge(timings)
  end

  @doc """
  Erases examples: `feedback` is the feedback copied beside them, which goes,
  and `kept` the ones kept whole, which keep only their identity, every field
  of `bodies` emptied.
  """
  @spec erase(Ecto.Queryable.t(), Ecto.Queryable.t(), [atom()]) :: :ok
  def erase(feedback, kept, bodies) do
    now = Repo.now!()
    Repo.delete_all(feedback)

    Repo.update_all(kept,
      set: Enum.map(bodies, &{&1, nil}) ++ [forgotten_at: now, updated_at: now]
    )

    :ok
  end

  @doc """
  Reduces the line `line` makes of each example of `examples` through `fun`,
  as `Enum.reduce_while/3` does, `batch` rows at a time with their feedback in
  `feedback_order`. It reads in one transaction, so a file is one snapshot,
  and refuses with `:examples_not_kept` once `kept?` says keeping them is off:
  turning it off hid only the Settings link, and the file still came from
  its address and the mix tasks until retention deleted the examples
  (2026-10-04 review).
  """
  @spec reduce(
          (-> boolean()),
          Ecto.Queryable.t(),
          pos_integer(),
          Ecto.Queryable.t(),
          (struct() -> iodata()),
          acc,
          (iodata(), acc -> {:cont, acc} | {:halt, acc})
        ) :: {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(kept?, examples, batch, feedback_order, line, acc, fun) do
    Repo.transaction(
      fn ->
        unless kept?.(), do: Repo.rollback(:examples_not_kept)

        examples
        |> Repo.stream(max_rows: batch)
        |> Stream.chunk_every(batch)
        |> Stream.flat_map(&Repo.preload(&1, feedback: feedback_order))
        |> Stream.map(line)
        |> Enum.reduce_while(acc, fun)
      end,
      timeout: :infinity
    )
  end

  @doc "One copied feedback signal as an export line holds it."
  @spec signal(struct()) :: Jason.OrderedObject.t()
  def signal(feedback) do
    Jason.OrderedObject.new([
      {"kind", feedback.kind},
      {"value", feedback.value},
      {"category", feedback.category},
      {"occurred_at", DateTime.to_iso8601(feedback.occurred_at)}
    ])
  end

  defp estimate(counts, target, at) when is_binary(target) do
    tokens = %{
      input: counts["input_tokens"],
      cached: counts["cached_input_tokens"],
      output: counts["output_tokens"],
      reasoning: counts["reasoning_tokens"]
    }

    with true <- Enum.all?(Map.values(tokens), &(is_integer(&1) or is_nil(&1))),
         {:ok, price} <- Pricing.fetch_in_effect(target, DateTime.to_date(at)) do
      price |> Pricing.estimate(tokens) |> Decimal.normalize() |> Decimal.to_string(:normal)
    else
      _unpriced -> nil
    end
  end

  defp estimate(_counts, _target, _at), do: nil
end
