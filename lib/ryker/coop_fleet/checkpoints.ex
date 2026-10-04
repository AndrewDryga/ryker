defmodule Ryker.CoopFleet.Checkpoints do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.CoopFleet.{
    Bodies,
    Bridge,
    CheckpointSecretScan,
    Command,
    ControlPlane,
    Placement,
    WorkspaceCheckpoint,
    WorkspaceCheckpointBundle,
    WorkspaceCheckpointTransfer
  }

  alias Ryker.Repo
  alias Ryker.Work.{RepositorySource, Session}

  def capture(session_id, key, response, options) do
    with :ok <- configured_secrets(options),
         %Command{} = producer <-
           Repo.get_by(Command, idempotency_key: key, session_id: session_id),
         %{"checkpoint" => checkpoint, "operation" => %{"id" => operation_id}} <- response,
         :ok <- producer_authority(producer, checkpoint, operation_id),
         {:ok, command} <-
           ControlPlane.enqueue_command(
             producer.placement_id,
             "get_checkpoint_bundle",
             %{"operation_id" => operation_id},
             "ryker:checkpoint:bundle:#{producer.id}:#{operation_id}"
           ),
         {:ok, result} <- Bridge.await_command(command.id, options),
         {:ok, transfer} <- store(producer, command, checkpoint, result, options) do
      {:ok,
       %{
         "transfer_id" => transfer.id,
         "checkpoint_ref" => transfer.checkpoint_ref,
         "sha256" => transfer.bundle_sha256,
         "bytes" => transfer.bundle_byte_size,
         "state" => "stored"
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :checkpoint_not_available}
    end
  end

  defp producer_authority(command, checkpoint, operation_id) do
    with {:ok, checkpoint} <- WorkspaceCheckpoint.validate(checkpoint),
         %{
           "status" => status,
           "body" => %{
             "checkpoint" => ^checkpoint,
             "operation" => %{
               "id" => ^operation_id,
               "method" => "CheckpointWorkspace",
               "state" => "succeeded"
             }
           }
         } <- command.result,
         true <-
           status in 200..299 and command.status == :succeeded and
             command.kind == "checkpoint_workspace",
         true <-
           checkpoint["session_ref"] == command.session_id and
             checkpoint["placement_generation"] == command.placement_generation and
             checkpoint["repository_ref"] == command.payload["repository_ref"] and
             command.payload["session_ref"] == command.session_id do
      :ok
    else
      _ -> {:error, :checkpoint_not_authorized}
    end
  end

  defp store(
         producer,
         command,
         checkpoint,
         %{stored_body: body, body_ref: reference, headers: headers},
         options
       ) do
    key = options[:checkpoint_key]

    with true <- reference == Map.take(checkpoint["bundle"], ~w(sha256 byte_size)),
         true <- body.command_id == command.id and body.direction == :response,
         true <- headers["Content-Type"] == checkpoint["bundle"]["media_type"],
         true <- headers["Etag"] == ~s("#{reference["sha256"]}"),
         {:ok, _manifest} <-
           Bodies.with_stream(body, key, fn stream ->
             WorkspaceCheckpointBundle.validate_stream(
               checkpoint,
               stream.(),
               options[:checkpoint_secrets]
             )
           end) do
      prepared = %{
        id: Ecto.UUID.generate(),
        command_id: producer.id,
        body_command_id: command.id,
        worker_id: producer.worker_id,
        session_ref: producer.session_id,
        placement_generation: producer.placement_generation,
        repository_ref: checkpoint["repository_ref"],
        checkpoint_ref: checkpoint["checkpoint_ref"],
        descriptor: checkpoint,
        bundle_sha256: reference["sha256"],
        bundle_byte_size: reference["byte_size"],
        encryption_key_sha256: digest(Ryker.Secret.reveal(key))
      }

      persist_transfer(prepared)
    else
      false -> {:error, :checkpoint_identity_mismatch}
      error -> error
    end
  end

  defp store(_, _, _, _, _), do: {:error, :checkpoint_not_available}

  defp persist_transfer(prepared) do
    changeset =
      %WorkspaceCheckpointTransfer{}
      |> cast(prepared, Map.keys(prepared))
      |> validate_required(Map.keys(prepared))

    # The data and receipt have already been fsynced before the result was
    # acknowledged. Only metadata belongs in this short transaction.
    Repo.transaction(fn ->
      Repo.insert!(changeset,
        on_conflict: :nothing,
        conflict_target: [:command_id, :checkpoint_ref]
      )

      saved =
        Repo.get_by!(WorkspaceCheckpointTransfer,
          command_id: prepared.command_id,
          checkpoint_ref: prepared.checkpoint_ref
        )

      if Map.take(saved, Map.keys(prepared) -- [:id]) != Map.delete(prepared, :id),
        do: Repo.rollback(:checkpoint_conflict)

      saved
    end)
  end

  # Run outside the heartbeat transaction. A restart retries the same immutable
  # command; polling defers it until this request body has durable custody.
  def prepare_restore(
        %Command{kind: "ensure_workspace", payload: %{"checkpoint" => saved}} = command,
        options
      ) do
    with :ok <- configured_secrets(options),
         %WorkspaceCheckpointTransfer{} = transfer <-
           Repo.get(WorkspaceCheckpointTransfer, saved["transfer_id"]),
         :ok <- restore_authority(command, transfer),
         :ok <-
           with_checkpoint(transfer, options, fn stream ->
             copy_checkpoint_to_request(command, transfer, stream, options)
           end) do
      :ok
    else
      nil -> {:error, :checkpoint_not_available}
      error -> error
    end
  end

  def prepare_restore(_command, _options), do: :ok

  defp copy_checkpoint_to_request(command, transfer, stream, options) do
    with {:ok, _} <-
           WorkspaceCheckpointBundle.validate_stream(
             transfer.descriptor,
             stream.(),
             options[:checkpoint_secrets]
           ) do
      Bodies.put(
        options[:body_root],
        command.id,
        :request,
        reference(transfer),
        stream.(),
        options[:checkpoint_key]
      )
    end
  end

  defp configured_secrets(options) do
    case CheckpointSecretScan.new(options[:checkpoint_secrets]) do
      {:ok, _} -> :ok
      _ -> {:error, :checkpoint_secret_configuration}
    end
  end

  defp restore_authority(command, transfer) do
    source_command = Repo.get(Command, transfer.command_id)
    source = source_command && Repo.get(Session, source_command.session_id)
    target = Repo.get(Session, command.session_id)
    placement = Repo.get(Placement, command.placement_id)

    if leased_placement?(placement, command) and same_source_sessions?(source, target) and
         command.payload["checkpoint"] == saved_checkpoint(transfer) do
      :ok
    else
      {:error, :checkpoint_not_authorized}
    end
  end

  defp leased_placement?(%Placement{state: :active} = placement, command),
    do:
      placement.worker_id == command.worker_id and
        placement.generation == command.placement_generation and
        DateTime.compare(placement.lease_expires_at, Repo.now!()) == :gt

  defp leased_placement?(_placement, _command), do: false

  defp same_source_sessions?(%Session{} = source, %Session{} = target),
    do:
      source.episode_id == target.episode_id and
        source.repository_ref == target.repository_ref and
        RepositorySource.same?(source.repository_source, target.repository_source)

  defp same_source_sessions?(_source, _target), do: false

  defp saved_checkpoint(transfer),
    do: %{
      "transfer_id" => transfer.id,
      "checkpoint_ref" => transfer.checkpoint_ref,
      "sha256" => transfer.bundle_sha256,
      "byte_size" => transfer.bundle_byte_size,
      "source_session_ref" => transfer.session_ref,
      "source_placement_generation" => transfer.placement_generation
    }

  # Only a version 2 checkpoint is restored, and every one was stored as an
  # encrypted file: the rows kept in PostgreSQL are all version 1.
  defp with_checkpoint(transfer, options, consume) do
    with {:ok, body, _} <-
           Bodies.fetch(
             options[:body_root],
             transfer.body_command_id,
             :response,
             reference(transfer)
           ) do
      Bodies.with_stream(body, options[:checkpoint_key], consume)
    end
  end

  defp reference(transfer),
    do: %{"sha256" => transfer.bundle_sha256, "byte_size" => transfer.bundle_byte_size}

  defp digest(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
