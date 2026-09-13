defmodule Ryker.CoopFleet.ControlPlane do
  @moduledoc """
  Durable registry, placement, command, and ordered-event custody for Coop workers.

  This module is the entry point over the parts. Worker identity and the poll
  transaction live in `Ryker.CoopFleet.ControlPlane.Workers`, session
  placement in `Ryker.CoopFleet.ControlPlane.Placements`, the command queue
  in `Ryker.CoopFleet.ControlPlane.Commands`, and ordered event custody in
  `Ryker.CoopFleet.ControlPlane.Events`; the helpers more than one of them
  needs sit in `Ryker.CoopFleet.ControlPlane.Shared`.

  The caller authenticates the worker transport before `handle_poll/3`. The
  poll then binds that identity to an enrolled worker row, applies the whole
  poll transactionally, and returns only commands for current leased
  placements. It records remote events before later runtime projection; a
  network acknowledgement never outruns durable receipt.
  """

  alias Ryker.CoopFleet.{Command, Placement, Worker}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Placements, Workers}
  alias Ryker.Work.Session

  @doc false
  @spec authorize_worker(String.t(), String.t(), String.t()) ::
          {:ok, Worker.t()} | {:error, term()}
  defdelegate authorize_worker(worker_id, workspace_ref, certificate_sha256), to: Workers

  @spec handle_poll_certificate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate handle_poll_certificate(certificate, document, options \\ []), to: Workers

  @spec authenticate_certificate(binary()) :: {:ok, String.t()} | {:error, term()}
  defdelegate authenticate_certificate(certificate), to: Workers

  @spec handle_poll(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_poll(authenticated_worker_id, document, options \\ []), to: Workers

  @spec place_session(Ecto.UUID.t(), map(), pos_integer()) ::
          {:ok, Placement.t()} | {:error, term()}
  defdelegate place_session(session_id, requirements, lease_seconds), to: Placements

  @doc """
  Whether any current worker could take this session's next placement.

  A recovery surface may only offer to move work when the fleet could actually
  accept it. The learning lane sat unplaceable for twelve hours on 2026-09-11
  because one worker advertised no digest for its policy, so this asks the same
  question placement asks — policy, authority, repository, capabilities,
  freshness and capacity — without taking a slot to find out.
  """
  @spec worker_available?(Session.t(), map()) :: boolean()
  defdelegate worker_available?(session, requirements), to: Placements

  @doc """
  The snapshot this session's work could continue from on another worker.

  Both halves must hold: a checkpoint the host still has for the exact source
  the session is pinned to, and a worker that could take it. Either one missing
  means the offer is a promise the fleet cannot keep, and the operator would
  lose the working copy by accepting it.
  """
  @spec portable_workspace(Session.t(), map()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  defdelegate portable_workspace(session, requirements), to: Placements

  @spec enqueue_command(Ecto.UUID.t(), String.t(), map(), String.t()) ::
          {:ok, Command.t()} | {:error, term()}
  defdelegate enqueue_command(placement_id, kind, payload, idempotency_key), to: Commands
end
