defmodule Ryker.CoopFleet.SessionEvidenceCapture do
  @moduledoc """
  Best-effort capture of one worker's session evidence, at its owning boundary.

  Observation must never change what was observed. Nothing here can fail a turn,
  spend a generation, alter a prompt or add an external effect: every outcome is
  reported as a reason and discarded by the caller, exactly like narration sync.
  A worker that does not advertise the export is left unknown, because an
  absence recorded as an observation is how "we never asked" becomes "there was
  no network".
  """

  import Ecto.Query

  alias Ryker.CoopFleet.{Placement, SessionEvidence, Worker}
  alias Ryker.Repo
  alias Ryker.Work.Session

  @capability "session-evidence"
  @version "1"

  @doc """
  Captures and records evidence for one bound session.

  Returns `{:ok, result}` when a capture was recorded, or `{:skipped, reason}` /
  `{:error, reason}` otherwise. Callers discard the result; it is returned for
  tests and for the operator log, never to steer execution.
  """
  @spec capture(Session.t(), module(), term()) ::
          {:ok, map()} | {:skipped, atom()} | {:error, term()}
  def capture(session, api, client)

  def capture(%Session{coop_session_id: remote} = session, api, client)
      when is_binary(remote) and is_atom(api) do
    with :ok <- exported?(api),
         {:ok, placement} <- current_placement(session.id),
         :ok <- advertises_export?(placement.worker_id),
         {:ok, document} <- read(api, client, remote) do
      SessionEvidence.record(session.id, document,
        worker_id: placement.worker_id,
        placement_generation: placement.generation
      )
    end
  rescue
    # A recorder that raises must not take the turn with it. The exception is
    # the reason; there is nothing about it a caller should act on.
    error -> {:error, {:coop_session_evidence_capture, Exception.message(error)}}
  catch
    # An exit is the same failure wearing different clothes: a transport process
    # that died mid-read would otherwise kill the caller, which is the executor
    # holding a turn that has already been accepted.
    :exit, reason -> {:error, {:coop_session_evidence_capture, inspect(reason)}}
  end

  def capture(%Session{}, _api, _client), do: {:skipped, :session_not_bound}
  def capture(_session, _api, _client), do: {:skipped, :session_not_bound}

  defp exported?(api) do
    if Code.ensure_loaded?(api) and function_exported?(api, :get_session_evidence, 2),
      do: :ok,
      else: {:skipped, :export_unsupported}
  end

  defp current_placement(session_id) do
    Repo.one(
      from(placement in Placement,
        where: placement.session_id == ^session_id and placement.state == :active,
        order_by: [desc: placement.generation],
        limit: 1
      )
    )
    |> case do
      %Placement{} = placement -> {:ok, placement}
      nil -> {:skipped, :no_active_placement}
    end
  end

  # The capability is the worker's own live proof, republished on every poll. A
  # worker that stops advertising it stops being asked, rather than producing a
  # failure the operator has to read past.
  defp advertises_export?(worker_id) do
    case Repo.get(Worker, worker_id) do
      %Worker{capabilities: capabilities} when is_list(capabilities) ->
        if Enum.any?(capabilities, &(&1["name"] == @capability and &1["version"] == @version)),
          do: :ok,
          else: {:skipped, :export_not_advertised}

      _absent_or_unknown ->
        {:skipped, :export_not_advertised}
    end
  end

  defp read(api, client, remote) do
    case api.get_session_evidence(client, remote) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :session_evidence}}
      {:error, _reason} = error -> error
    end
  end
end
