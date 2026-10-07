defmodule Ryker.BundledCoop do
  @moduledoc """
  Enrolls the Compose worker and selects its workspace.

  Jobs carry their own code and settings. The shared directory contains only
  enrollment state and the controller CA, never policies or repository checkouts.
  """

  alias Ryker.AdvisoryLock
  alias Ryker.CoopFleet.{Enrollment, EnrollmentToken, Worker}
  alias Ryker.Crypto
  alias Ryker.{Repo, Settings}

  @actor "control-plane:local"
  @shared_env "RYKER_BUNDLED_COOP_SHARED"

  @doc "Whether this installation runs the Compose distribution's bundled worker."
  def distribution?, do: not is_nil(System.get_env(@shared_env))

  @doc false
  def prepare_distribution! do
    {:ok, snapshot} = Settings.initialize(@actor)

    if snapshot.work.workspace_ref != configured_workspace_ref() do
      {:ok, _snapshot} =
        Settings.save_work(
          %{workspace_ref: configured_workspace_ref()},
          snapshot.installation.revision,
          @actor
        )
    end

    ensure_enrollment_file!()
  end

  @doc false
  def ensure_enrollment_file! do
    shared = System.fetch_env!(@shared_env)
    File.mkdir_p!(shared)
    File.chmod!(shared, 0o700)

    case Repo.transaction(fn ->
           AdvisoryLock.hold!("bundled-coop-enrollment:#{configured_worker_id()}")

           ensure_token!(shared)
         end) do
      {:ok, :ok} -> :ok
      {:error, :coop_worker_enrollment_not_authorized} -> :ok
      {:error, reason} -> raise "bundled co:op enrollment failed: #{inspect(reason)}"
    end
  end

  defp ensure_token!(shared) do
    token_path = Path.join(shared, "enrollment-token")
    marker = Path.join(shared, "enrolled")

    cond do
      File.exists?(marker) or revoked?() ->
        retire_tokens!(token_path)

      usable_token?(token_path) ->
        :ok

      true ->
        issue_token!(token_path, marker)
    end

    :ok
  end

  defp issue_token!(path, marker) do
    case Enrollment.issue_token(configured_worker_id(), configured_workspace_ref(), @actor, 3_600) do
      {:ok, issued} ->
        # A marker proves Coop persisted the identity, not merely that Ryker issued it.
        if File.exists?(marker),
          do: retire_tokens!(path),
          else: atomic_write!(path, issued.token)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp revoked?, do: match?(%Worker{state: :revoked}, configured_worker())

  defp configured_worker, do: Repo.one(Worker.Query.by_id(configured_worker_id()))

  defp retire_tokens!(path) do
    worker = configured_worker_id()
    workspace = configured_workspace_ref()
    now = Repo.now!()

    worker
    |> EnrollmentToken.Query.by_worker_id_and_workspace_ref(workspace)
    |> EnrollmentToken.Query.by_operator(@actor)
    |> EnrollmentToken.Query.usable_at(now)
    |> Repo.update_all(set: [expires_at: now])

    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove enrollment token", path: path
    end
  end

  defp usable_token?(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        false

      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} when size in 32..129 ->
        unless Bitwise.band(mode, 0o777) == 0o600,
          do: raise("bundled co:op enrollment token must be private")

        token = File.open!(path, [:read, :binary], &IO.binread(&1, 130)) |> String.trim()

        unless String.valid?(token) and byte_size(token) in 32..128,
          do: raise("bundled co:op enrollment token is invalid")

        token_authorized?(token)

      _invalid ->
        raise "bundled co:op enrollment token must be a bounded private regular file"
    end
  end

  defp token_authorized?(token) do
    digest = Crypto.sha256_hex(token)
    worker = configured_worker_id()
    workspace = configured_workspace_ref()
    now = Repo.now!()

    digest
    |> EnrollmentToken.Query.by_digest()
    |> EnrollmentToken.Query.by_worker_id_and_workspace_ref(worker, workspace)
    |> EnrollmentToken.Query.usable_at(now)
    |> Repo.exists?()
  end

  @doc false
  def ready? do
    worker = configured_worker()
    snapshot = Settings.fetch!()

    worker_ready?(worker) and snapshot.work.workspace_ref == configured_workspace_ref()
  rescue
    error ->
      Ryker.Rescued.log("Bundled Coop readiness", error, __STACKTRACE__)
      false
  end

  defp worker_ready?(
         %Worker{state: :eligible, protocol_version: "2", last_seen_at: %DateTime{}} = worker
       ) do
    cutoff = DateTime.add(DateTime.utc_now(), -Worker.heartbeat_seconds(), :second)
    capacity = worker.capacity || %{}

    worker.workspace_ref == configured_workspace_ref() and
      DateTime.compare(worker.last_seen_at, cutoff) != :lt and capacity["state"] == "eligible" and
      Enum.all?(~w(session turn workspace), fn kind ->
        is_integer(capacity["#{kind}_slots_free"]) and capacity["#{kind}_slots_free"] > 0
      end) and
      %{"name" => "controller-tools", "version" => "1"} in worker.capabilities
  end

  defp worker_ready?(_worker), do: false

  defp atomic_write!(path, content) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    try do
      File.open!(temporary, [:write, :binary, :exclusive], fn file ->
        File.chmod!(temporary, 0o600)
        :ok = IO.binwrite(file, content)
        :ok = :file.sync(file)
      end)

      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp configured_worker_id,
    do: System.get_env("RYKER_BUNDLED_COOP_WORKER_ID", "ryker-compose")

  defp configured_workspace_ref,
    do: System.get_env("RYKER_BUNDLED_COOP_WORKSPACE", "ryker-compose")
end
