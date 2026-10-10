defmodule Ryker.CoopFleet.ControlPlane do
  @moduledoc """
  Durable registry, placement, command, and ordered-event custody for Coop workers.

  This module is the entry point over the parts. Worker identity and the poll
  transaction live in `Ryker.CoopFleet.ControlPlane.Workers`, session
  placement in `Ryker.CoopFleet.ControlPlane.Placements`, the command queue
  in `Ryker.CoopFleet.ControlPlane.Commands`, and ordered event custody in
  `Ryker.CoopFleet.ControlPlane.Events`; the helpers more than one of them
  needs sit in `Ryker.CoopFleet.ControlPlane.Shared`.

  A poll names the worker by the client certificate it came with
  (`handle_poll_certificate/3`): the certificate's digest must be one the
  worker holds now. The poll then applies the whole poll transactionally and
  returns only commands for current leased placements. It records remote events before later runtime projection; a
  network acknowledgement never outruns durable receipt.
  """
  alias Ryker.CoopFleet.{Command, Placement}
  alias Ryker.CoopFleet.ControlPlane.{Commands, Placements, Workers}
  alias Ryker.Work

  @spec handle_poll_certificate(binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defdelegate handle_poll_certificate(certificate, document, options \\ []), to: Workers

  @spec authenticate_certificate(binary()) :: {:ok, String.t()} | {:error, term()}
  defdelegate authenticate_certificate(certificate), to: Workers

  @spec place_session(Ecto.UUID.t(), map(), pos_integer()) ::
          {:ok, Placement.t()} | {:error, term()}
  defdelegate place_session(session_id, requirements, lease_seconds), to: Placements

  @spec retire_session_placements(Ecto.UUID.t(), DateTime.t()) :: :ok
  defdelegate retire_session_placements(session_id, now), to: Placements

  @doc "Retires the placements no worker will renew."
  defdelegate retire_abandoned_placements(now, up_since), to: Placements

  @spec awaiting_worker?(Ecto.UUID.t()) :: boolean()
  defdelegate awaiting_worker?(session_id), to: Placements

  @doc """
  Whether any current worker could take this session's next placement.

  A recovery surface may only offer to move work when the fleet could actually
  accept it. This asks the same question placement asks — frozen job authority,
  workspace, capabilities, freshness and capacity — without taking a slot to
  find out. Retired policy and repository advertisements are not authority.
  """
  @spec worker_available?(Work.Session.t(), map()) :: boolean()
  defdelegate worker_available?(session, requirements), to: Placements

  @doc """
  Whether the worker holding this session has nothing else to do, so a
  prepare sent to it holds up no other work.
  """
  @spec worker_idle?(Ecto.UUID.t()) :: boolean()
  defdelegate worker_idle?(session_id), to: Placements

  @doc """
  The snapshot this session's work could continue from on another worker.

  Both halves must hold: a checkpoint the host still has for the exact source
  the session is pinned to, and a worker that could take it. Either one missing
  means the offer is a promise the fleet cannot keep, and the operator would
  lose the working copy by accepting it.
  """
  @spec portable_workspace(Work.Session.t(), map(), String.t()) ::
          %{byte_size: pos_integer(), checkpoint_ref: String.t(), repository_ref: String.t()}
          | nil
  defdelegate portable_workspace(session, requirements, body_root), to: Placements

  @spec enqueue_command(Ecto.UUID.t(), String.t(), map(), String.t()) ::
          {:ok, Command.t()} | {:error, term()}
  defdelegate enqueue_command(placement_id, kind, payload, idempotency_key), to: Commands

  @doc false
  defdelegate fence_command(session, kind, intent, key), to: Commands
end
