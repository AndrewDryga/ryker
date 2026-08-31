defmodule Responder.CoopFleet.ArtifactTransport do
  @moduledoc """
  Authenticated binary custody for one durable worker command.

  Input bytes can be read only when the current worker command's frozen
  submission names the exact artifact. Output bytes can be written only when
  the current command names the exact Coop output artifact. The JSON poll
  protocol therefore stays bounded while attachment bytes retain the same
  worker, placement, and command fences.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Responder.Artifacts

  alias Responder.CoopFleet.{
    CheckpointCrypto,
    Command,
    ControlPlane,
    OutputTransfer,
    Placement,
    ReviewPatchTransfer,
    WorkspaceCheckpoint,
    WorkspaceCheckpointBundle,
    WorkspaceCheckpointTransfer
  }

  alias Responder.Repo

  @maximum_bytes 8 * 1_024 * 1_024
  @maximum_review_patch_bytes 64 * 1_024 * 1_024
  @media_types ~w(image/png image/jpeg image/webp image/gif)
  @reference ~r/\A[A-Za-z0-9_.:-]{1,256}\z/

  @spec fetch_input(binary(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_input(certificate, command_id, artifact_ref) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command} <-
           current_command(worker_id, command_id, ["submit_turn", "fence_operation"]),
         {:ok, artifact_refs} <- input_artifact_refs(command),
         true <- artifact_ref in artifact_refs,
         {:ok, [artifact]} <- Artifacts.fetch_many([artifact_ref]) do
      {:ok,
       %{
         data: artifact.data,
         media_type: artifact.media_type,
         name: artifact.name,
         sha256: artifact.sha256
       }}
    else
      false -> {:error, :coop_worker_artifact_not_authorized}
      {:error, _reason} = error -> error
      _invalid -> {:error, :coop_worker_artifact_not_authorized}
    end
  end

  @spec put_output(binary(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, OutputTransfer.t()} | {:error, term()}
  def put_output(certificate, command_id, artifact_ref, attributes) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command} <- current_command(worker_id, command_id, "get_output_artifact"),
         true <- command.payload["artifact_ref"] == artifact_ref,
         {:ok, prepared} <- prepare_output(worker_id, command_id, artifact_ref, attributes) do
      insert_or_reconcile(prepared)
    else
      false -> {:error, :coop_worker_artifact_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_output(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def fetch_output(transfer_id) do
    case Ecto.UUID.cast(transfer_id) do
      {:ok, transfer_id} ->
        case Repo.get(OutputTransfer, transfer_id) do
          %OutputTransfer{} = transfer ->
            {:ok,
             %{
               "bytes" => transfer.byte_size,
               "data" => transfer.data,
               "id" => transfer.artifact_ref,
               "media_type" => transfer.media_type,
               "name" => transfer.name,
               "sha256" => transfer.sha256
             }}

          nil ->
            {:error, :coop_worker_output_artifact_not_found}
        end

      :error ->
        {:error, :coop_worker_output_artifact_not_found}
    end
  end

  @spec put_review_patch(binary(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, ReviewPatchTransfer.t()} | {:error, term()}
  def put_review_patch(certificate, command_id, artifact_id, attributes) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command} <- current_command(worker_id, command_id, "get_review_patch"),
         true <- command.payload["artifact_id"] == artifact_id,
         true <- command.payload["expected_sha256"] == attributes[:sha256],
         true <- command.payload["expected_bytes"] == byte_size(attributes[:data] || <<>>),
         {:ok, prepared} <- prepare_review_patch(worker_id, command_id, artifact_id, attributes) do
      insert_or_reconcile_review_patch(prepared)
    else
      false -> {:error, :coop_worker_artifact_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_review_patch(Ecto.UUID.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_review_patch(transfer_id) do
    case Ecto.UUID.cast(transfer_id) do
      {:ok, transfer_id} ->
        case Repo.get(ReviewPatchTransfer, transfer_id) do
          %ReviewPatchTransfer{data: data} -> {:ok, data}
          nil -> {:error, :coop_worker_review_patch_not_found}
        end

      :error ->
        {:error, :coop_worker_review_patch_not_found}
    end
  end

  @spec put_checkpoint(binary(), Ecto.UUID.t(), String.t(), map(), binary(), [binary()]) ::
          {:ok, WorkspaceCheckpointTransfer.t()} | {:error, term()}
  def put_checkpoint(
        certificate,
        command_id,
        checkpoint_ref,
        %{checkpoint: checkpoint, bundle: bundle},
        key,
        secrets
      ) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command} <- current_command(worker_id, command_id, "checkpoint_workspace"),
         :ok <- checkpoint_authority(command, checkpoint_ref, checkpoint),
         {:ok, _manifest} <- WorkspaceCheckpointBundle.validate(checkpoint, bundle, secrets),
         {:ok, sealed} <- CheckpointCrypto.seal(key, checkpoint, bundle),
         {:ok, prepared} <- prepare_checkpoint(worker_id, command, checkpoint, sealed) do
      insert_or_reconcile_checkpoint(prepared)
    else
      {:error, _reason} = error -> error
    end
  end

  def put_checkpoint(_certificate, _command_id, _checkpoint_ref, _attributes, _key, _secrets),
    do: {:error, {:invalid_coop_worker_workspace_checkpoint, :fields}}

  @spec fetch_checkpoint(Ecto.UUID.t(), binary()) :: {:ok, map()} | {:error, term()}
  def fetch_checkpoint(transfer_id, key) do
    with {:ok, transfer_id} <- Ecto.UUID.cast(transfer_id),
         %WorkspaceCheckpointTransfer{} = transfer <-
           Repo.get(WorkspaceCheckpointTransfer, transfer_id),
         {:ok, bundle} <-
           CheckpointCrypto.open(
             key,
             transfer.descriptor,
             transfer.ciphertext,
             transfer.encryption_nonce,
             transfer.encryption_tag,
             transfer.encryption_key_sha256
           ),
         {:ok, _manifest} <-
           WorkspaceCheckpointBundle.validate(transfer.descriptor, bundle, []) do
      {:ok, %{bundle: bundle, checkpoint: transfer.descriptor, transfer: transfer}}
    else
      :error -> {:error, :coop_worker_workspace_checkpoint_not_found}
      nil -> {:error, :coop_worker_workspace_checkpoint_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_checkpoint_for_restore(
          binary(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          binary(),
          [binary()]
        ) :: {:ok, map()} | {:error, term()}
  def fetch_checkpoint_for_restore(
        certificate,
        command_id,
        transfer_id,
        key,
        secrets
      ) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command} <- current_command(worker_id, command_id, "ensure_workspace"),
         {:ok, transfer_id} <- Ecto.UUID.cast(transfer_id),
         %WorkspaceCheckpointTransfer{} = transfer <-
           Repo.get(WorkspaceCheckpointTransfer, transfer_id),
         :ok <- restore_authority(command, transfer),
         {:ok, stored} <- fetch_checkpoint(transfer_id, key),
         {:ok, _manifest} <-
           WorkspaceCheckpointBundle.validate(stored.checkpoint, stored.bundle, secrets) do
      {:ok, stored}
    else
      :error -> {:error, :coop_worker_workspace_checkpoint_not_authorized}
      nil -> {:error, :coop_worker_workspace_checkpoint_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  defp current_command(worker_id, command_id, kind) do
    case Ecto.UUID.cast(command_id) do
      {:ok, command_id} ->
        kinds = if is_list(kind), do: kind, else: [kind]
        authorized_command(worker_id, command_id, kinds, database_now!())

      :error ->
        {:error, :coop_worker_artifact_not_authorized}
    end
  end

  defp authorized_command(worker_id, command_id, kinds, now) do
    query =
      from(command in Command,
        join: placement in Placement,
        on: placement.id == command.placement_id,
        where:
          command.id == ^command_id and command.worker_id == ^worker_id and
            command.kind in ^kinds and command.status in [:delivered, :acknowledged] and
            placement.worker_id == ^worker_id and placement.state == :active and
            placement.lease_expires_at > ^now,
        select: command
      )

    case Repo.one(query) do
      %Command{} = command -> {:ok, command}
      nil -> {:error, :coop_worker_artifact_not_authorized}
    end
  end

  defp input_artifact_refs(%Command{
         kind: "submit_turn",
         payload: %{"submission" => %{"input_artifact_refs" => refs}}
       }),
       do: bounded_artifact_refs(refs)

  defp input_artifact_refs(%Command{
         kind: "fence_operation",
         payload: %{"input_artifact_refs" => refs, "method" => "SubmitTurn"}
       }),
       do: bounded_artifact_refs(refs)

  defp input_artifact_refs(_command), do: {:error, :coop_worker_artifact_not_authorized}

  defp bounded_artifact_refs(refs) when is_list(refs) and length(refs) <= 5 do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &is_binary/1),
      do: {:ok, refs},
      else: {:error, :coop_worker_artifact_not_authorized}
  end

  defp bounded_artifact_refs(_refs), do: {:error, :coop_worker_artifact_not_authorized}

  defp prepare_output(worker_id, command_id, artifact_ref, %{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == [:data, :media_type, :name, :sha256] and
         Regex.match?(@reference, artifact_ref) and valid_name?(attributes.name) and
         attributes.media_type in @media_types and digest(attributes.data) == attributes.sha256 and
         byte_size(attributes.data) in 1..@maximum_bytes do
      {:ok,
       %{
         artifact_ref: artifact_ref,
         byte_size: byte_size(attributes.data),
         command_id: command_id,
         data: attributes.data,
         id: Ecto.UUID.generate(),
         media_type: attributes.media_type,
         name: attributes.name,
         sha256: attributes.sha256,
         worker_id: worker_id
       }}
    else
      {:error, {:invalid_coop_worker_output_artifact, :fields}}
    end
  end

  defp prepare_output(_worker_id, _command_id, _artifact_ref, _attributes),
    do: {:error, {:invalid_coop_worker_output_artifact, :fields}}

  defp prepare_review_patch(worker_id, command_id, artifact_id, %{
         data: data,
         sha256: sha256
       }) do
    if Regex.match?(@reference, artifact_id) and is_binary(data) and
         byte_size(data) in 1..@maximum_review_patch_bytes and digest(data) == sha256 do
      {:ok,
       %{
         artifact_id: artifact_id,
         byte_size: byte_size(data),
         command_id: command_id,
         data: data,
         id: Ecto.UUID.generate(),
         sha256: sha256,
         worker_id: worker_id
       }}
    else
      {:error, {:invalid_coop_worker_review_patch, :fields}}
    end
  end

  defp prepare_review_patch(_worker_id, _command_id, _artifact_id, _attributes),
    do: {:error, {:invalid_coop_worker_review_patch, :fields}}

  defp checkpoint_authority(command, checkpoint_ref, checkpoint) do
    payload = command.payload

    if is_map(checkpoint) and checkpoint["checkpoint_ref"] == checkpoint_ref and
         checkpoint["session_ref"] == command.session_id and
         checkpoint["placement_generation"] == command.placement_generation and
         payload["session_ref"] == command.session_id and
         payload["repository_ref"] == checkpoint["repository_ref"],
       do: :ok,
       else: {:error, :coop_worker_workspace_checkpoint_not_authorized}
  end

  defp restore_authority(command, transfer) do
    restore = command.payload["checkpoint"]
    source_command = Repo.get(Command, transfer.command_id)
    source_placement = placement_for_command(source_command)
    target_placement = Repo.get(Placement, command.placement_id)

    with true <- exact_restore_reference?(restore, transfer),
         %Placement{} <- source_placement,
         %Placement{} <- target_placement,
         true <- source_placement.episode_id == target_placement.episode_id do
      :ok
    else
      _unauthorized -> {:error, :coop_worker_workspace_checkpoint_not_authorized}
    end
  end

  defp exact_restore_reference?(restore, transfer) do
    is_map(restore) and restore["transfer_id"] == transfer.id and
      restore["checkpoint_ref"] == transfer.checkpoint_ref and
      restore["sha256"] == transfer.bundle_sha256 and
      restore["byte_size"] == transfer.bundle_byte_size and
      restore["source_session_ref"] == transfer.session_ref and
      restore["source_placement_generation"] == transfer.placement_generation
  end

  defp placement_for_command(nil), do: nil
  defp placement_for_command(command), do: Repo.get(Placement, command.placement_id)

  defp prepare_checkpoint(worker_id, command, checkpoint, sealed) do
    with {:ok, checkpoint} <- WorkspaceCheckpoint.validate(checkpoint) do
      {:ok,
       Map.merge(sealed, %{
         bundle_byte_size: checkpoint["bundle"]["byte_size"],
         bundle_sha256: checkpoint["bundle"]["sha256"],
         checkpoint_ref: checkpoint["checkpoint_ref"],
         command_id: command.id,
         descriptor: checkpoint,
         id: Ecto.UUID.generate(),
         placement_generation: checkpoint["placement_generation"],
         repository_ref: checkpoint["repository_ref"],
         session_ref: checkpoint["session_ref"],
         worker_id: worker_id
       })}
    end
  end

  defp insert_or_reconcile(prepared) do
    changeset =
      %OutputTransfer{}
      |> cast(prepared, [
        :artifact_ref,
        :byte_size,
        :command_id,
        :data,
        :id,
        :media_type,
        :name,
        :sha256,
        :worker_id
      ])
      |> validate_required([
        :artifact_ref,
        :byte_size,
        :command_id,
        :data,
        :id,
        :media_type,
        :name,
        :sha256,
        :worker_id
      ])
      |> unique_constraint([:command_id, :artifact_ref])
      |> foreign_key_constraint(:command_id,
        name: :coop_worker_output_transfer_command_worker_fkey
      )
      |> check_constraint(:artifact_ref, name: :coop_worker_output_transfer_identity_valid)

    case Repo.insert(changeset) do
      {:ok, transfer} ->
        {:ok, transfer}

      {:error, %Ecto.Changeset{}} ->
        reconcile_output_transfer(prepared, changeset)
    end
  end

  defp reconcile_output_transfer(prepared, changeset) do
    case Repo.get_by(OutputTransfer,
           command_id: prepared.command_id,
           artifact_ref: prepared.artifact_ref
         ) do
      %OutputTransfer{} = transfer ->
        if identity(transfer) == identity(prepared),
          do: {:ok, transfer},
          else: {:error, :coop_worker_output_artifact_conflict}

      nil ->
        {:error, changeset}
    end
  end

  defp insert_or_reconcile_review_patch(prepared) do
    changeset =
      %ReviewPatchTransfer{}
      |> cast(prepared, [
        :artifact_id,
        :byte_size,
        :command_id,
        :data,
        :id,
        :sha256,
        :worker_id
      ])
      |> validate_required([
        :artifact_id,
        :byte_size,
        :command_id,
        :data,
        :id,
        :sha256,
        :worker_id
      ])
      |> unique_constraint([:command_id, :artifact_id])
      |> foreign_key_constraint(:command_id,
        name: :coop_worker_review_patch_command_worker_fkey
      )
      |> check_constraint(:artifact_id, name: :coop_worker_review_patch_identity_valid)

    case Repo.insert(changeset) do
      {:ok, transfer} ->
        {:ok, transfer}

      {:error, %Ecto.Changeset{}} ->
        reconcile_review_patch(prepared, changeset)
    end
  end

  defp reconcile_review_patch(prepared, changeset) do
    case Repo.get_by(ReviewPatchTransfer,
           command_id: prepared.command_id,
           artifact_id: prepared.artifact_id
         ) do
      %ReviewPatchTransfer{} = transfer ->
        if review_patch_identity(transfer) == review_patch_identity(prepared),
          do: {:ok, transfer},
          else: {:error, :coop_worker_review_patch_conflict}

      nil ->
        {:error, changeset}
    end
  end

  defp insert_or_reconcile_checkpoint(prepared) do
    fields = [
      :bundle_byte_size,
      :bundle_sha256,
      :checkpoint_ref,
      :ciphertext,
      :command_id,
      :descriptor,
      :encryption_key_sha256,
      :encryption_nonce,
      :encryption_tag,
      :id,
      :placement_generation,
      :repository_ref,
      :session_ref,
      :worker_id
    ]

    changeset =
      %WorkspaceCheckpointTransfer{}
      |> cast(prepared, fields)
      |> validate_required(fields)
      |> unique_constraint([:command_id, :checkpoint_ref],
        name: :coop_worker_workspace_checkpoints_command_ref_index
      )
      |> foreign_key_constraint(:command_id,
        name: :coop_worker_workspace_checkpoint_command_worker_fkey
      )
      |> check_constraint(:checkpoint_ref,
        name: :coop_worker_workspace_checkpoint_identity_valid
      )

    case Repo.insert(changeset) do
      {:ok, transfer} -> {:ok, transfer}
      {:error, %Ecto.Changeset{}} -> reconcile_checkpoint(prepared, changeset)
    end
  end

  defp reconcile_checkpoint(prepared, changeset) do
    case Repo.get_by(WorkspaceCheckpointTransfer,
           command_id: prepared.command_id,
           checkpoint_ref: prepared.checkpoint_ref
         ) do
      %WorkspaceCheckpointTransfer{} = transfer ->
        if checkpoint_identity(transfer) == checkpoint_identity(prepared),
          do: {:ok, transfer},
          else: {:error, :coop_worker_workspace_checkpoint_conflict}

      nil ->
        {:error, changeset}
    end
  end

  defp identity(value),
    do:
      {value.command_id, value.worker_id, value.artifact_ref, value.name, value.media_type,
       value.sha256, value.byte_size, value.data}

  defp review_patch_identity(value),
    do:
      {value.command_id, value.worker_id, value.artifact_id, value.sha256, value.byte_size,
       value.data}

  defp checkpoint_identity(value),
    do:
      {value.command_id, value.worker_id, value.checkpoint_ref, value.session_ref,
       value.placement_generation, value.repository_ref, value.descriptor, value.bundle_sha256,
       value.bundle_byte_size, value.encryption_key_sha256}

  defp valid_name?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 == 127))
  end

  defp valid_name?(_value), do: false

  defp database_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp digest(data) when is_binary(data),
    do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp digest(_data), do: nil
end
