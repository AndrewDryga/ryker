defmodule Ryker.Repo do
  @moduledoc """
  The one PostgreSQL repository, and the clock and error classes custody
  compares against.

  Side effects that must not outlive a rollback, such as the announcements
  open pages redraw on (`Ryker.PubSub`), wait for the commit through
  `after_commit/1`. The rule for nesting: a callback registered anywhere
  inside a transaction runs once the outermost transaction this process
  opened commits, and never if it rolls back. Emisar instead refuses a nested
  after-commit and makes the caller hoist it to the outermost transaction;
  Ryker's custody writes join whatever transaction their caller opened, often
  several levels deep, so hoisting would mean threading every announcement
  back up through every custody call, and one forgotten would announce a
  change before it was visible.
  """
  use Ecto.Repo,
    adapter: Ecto.Adapters.Postgres,
    otp_app: :ryker

  require Logger

  # Every column is `timestamp without time zone` holding UTC, and SQL compares
  # them with now() and clock_timestamp(), which PostgreSQL reads in the
  # session's zone. Each connection asks for UTC, so a server in another zone
  # cannot shift every lease and retention horizon by its offset.
  def init(_context, config) do
    {:ok,
     Keyword.update(config, :parameters, [timezone: "UTC"], &Keyword.put(&1, :timezone, "UTC"))}
  end

  # The after-commit queue of the outermost transaction this process has open,
  # newest callback first. Absent outside a transaction Ryker.Repo started.
  @after_commit {__MODULE__, :after_commit}

  @doc """
  Runs `callback` once the outermost transaction this process has open
  commits, and never if it rolls back. Outside a transaction it runs at once.

  This is how a context announces a change (`Ryker.PubSub`): a broadcast made
  inside the transaction would reach a subscriber before the rows it names
  were visible, and survive a rollback that took them away.

  Ryker composes custody in deep transactions: a context's write joins
  whatever transaction its caller opened, and `Ryker.Settings.atomically/1`
  wraps several saves in one. Emisar refuses a nested after-commit and asks
  the caller to hoist it; here that would mean threading every broadcast up
  through every custody call. So a callback registered anywhere inside waits
  for the outermost commit instead. A nested transaction that fails dooms the
  outer one (PostgreSQL turns its COMMIT into a rollback), so nothing
  registered anywhere in it is announced.

  The same callback registered twice before one commit runs once, so a context
  can announce each row it writes without flooding subscribers. A callback
  that raises is logged and skipped: the transaction has committed, so its
  caller is told so.
  """
  @spec after_commit((-> term())) :: :ok
  def after_commit(callback) when is_function(callback, 0) do
    case Process.get(@after_commit) do
      nil -> run_after_commit([callback])
      # The open transaction's after-commit queue lives with it, as Ecto's own transaction state does.
      # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
      queue -> Process.put(@after_commit, [callback | queue])
    end

    :ok
  end

  # Every Repo.transaction/2 runs through transact/2, so this is the one place
  # that sees each transaction open and close.
  defoverridable transact: 2

  @doc false
  def transact(fun_or_multi, opts) do
    scope = open_after_commit_scope()

    try do
      super(fun_or_multi, opts)
    catch
      kind, reason ->
        close_after_commit_scope(scope, false)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        close_after_commit_scope(scope, committed?(result))
        result
    end
  end

  defp open_after_commit_scope do
    case Process.get(@after_commit) do
      nil ->
        # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
        Process.put(@after_commit, [])
        :outermost

      _queue ->
        :nested
    end
  end

  # Only the outermost transaction commits; a nested one that fails makes the
  # outermost roll back, so its result decides for every callback.
  defp close_after_commit_scope(:nested, _committed?), do: :ok

  defp close_after_commit_scope(:outermost, committed?) do
    queue = Process.delete(@after_commit)
    if committed?, do: queue |> Enum.reverse() |> Enum.uniq() |> run_after_commit()
    :ok
  end

  defp committed?({:ok, _value}), do: true
  defp committed?(_error), do: false

  defp run_after_commit(callbacks) do
    Enum.each(callbacks, fn callback ->
      try do
        callback.()
      rescue
        error ->
          # The commit stands; only its announcement is lost. Never log the
          # exception body: it can carry the payload.
          Logger.error("After-commit callback failed category=#{inspect(error.__struct__)}")
      end
    end)
  end

  @doc """
  The one row `queryable` selects, as `{:ok, row}`, or `{:error, :not_found}`
  when there is none; raises when more than one matches. The query comes from
  the schema's Query module (`Ryker.Checks.IL02NoRepoGet`).
  """
  @spec fetch(Ecto.Queryable.t(), keyword()) :: {:ok, struct()} | {:error, :not_found}
  def fetch(queryable, opts \\ []) do
    case one(queryable, opts) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @doc """
  The database's own clock at this instant, microsecond precision.

  Custody compares leases, placements and receipts against this rather than
  the VM clock so one writer's fences agree across restarts and hosts.
  """
  @spec now!() :: DateTime.t()
  def now! do
    %{rows: [[%DateTime{} = now]]} = query!("SELECT clock_timestamp()")
    now
  end

  @conflicts [:serialization_failure, :deadlock_detected]
  @exhausted [:query_canceled, :lock_not_available | @conflicts]

  @doc """
  Whether PostgreSQL refused a transaction because a concurrent one won.

  The snapshot it read is stale, and reading again may succeed.
  """
  @spec conflict?(Exception.t()) :: boolean()
  def conflict?(%Postgrex.Error{postgres: %{code: code}}), do: code in @conflicts
  def conflict?(_error), do: false

  @doc """
  Whether a bounded read gave up: its statement or lock timeout ran out, or
  it lost a conflict.
  """
  @spec budget_exhausted?(Exception.t()) :: boolean()
  def budget_exhausted?(%Postgrex.Error{postgres: %{code: code}}), do: code in @exhausted
  def budget_exhausted?(_error), do: false
end
