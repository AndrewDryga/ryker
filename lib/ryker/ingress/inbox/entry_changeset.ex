defmodule Ryker.Ingress.Inbox.EntryChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Admission.Decision
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Ingress.WorkProfile

  @execution_fields [
    :admission_context,
    :admission_context_fingerprint,
    :attempt_count,
    :execution_generation,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :validation_generation
  ]

  @spec bind_context(Entry.t(), map(), String.t()) :: Ecto.Changeset.t()
  def bind_context(%Entry{} = entry, context, fingerprint) do
    entry
    |> cast(
      %{admission_context: context, admission_context_fingerprint: fingerprint},
      [:admission_context, :admission_context_fingerprint]
    )
    |> validate_required([:admission_context, :admission_context_fingerprint])
    |> validate_length(:admission_context_fingerprint, is: 64)
    |> check_constraint(:admission_context,
      name: :ingress_inbox_admission_context_valid
    )
  end

  @envelope_bytes 65_536

  @spec insert(
          Input.t(),
          Ecto.UUID.t(),
          :live | :shadow,
          WorkProfile.t() | nil,
          map(),
          keyword()
        ) ::
          Ecto.Changeset.t()
  def insert(
        %Input{} = input,
        id,
        execution_mode,
        work_profile,
        slack_addressing,
        evidence \\ []
      )
      when execution_mode in [:live, :shadow] do
    fields = %{
      actor_kind: input.actor.kind,
      actor_ref: input.actor.ref,
      content: input.content,
      source_envelope: bounded_envelope(Keyword.get(evidence, :source_envelope)),
      engagement_receipt: bounded_receipt(Keyword.get(evidence, :engagement_receipt)),
      dedupe_key: Input.dedupe_key(input),
      destination_conversation_ref: input.destination.conversation_ref,
      destination_thread_ref: input.destination.thread_ref,
      destination_transport: input.destination.transport,
      event_fingerprint: Input.fingerprint(input),
      event_kind: input.event_kind,
      event_ref: input.event_ref,
      execution_mode: execution_mode,
      id: id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      occurred_at_source: input.occurred_at_source,
      revision: input.revision,
      source_kind: input.source.kind,
      source_capabilities: input.source_capabilities,
      source_ref: input.source.ref,
      source_item_ref: input.source_item_ref,
      slack_audience: slack_addressing.audience,
      slack_bot_user_ref: slack_addressing.bot_user_ref,
      status: :pending,
      work_profile: work_profile && WorkProfile.document(work_profile),
      work_policy: work_profile && work_profile.policy,
      work_policy_digest: work_profile && work_profile.policy_digest,
      repository_ref: work_profile && work_profile.repository_ref
    }

    %Entry{}
    |> cast(fields, Map.keys(fields) -- [:slack_audience, :slack_bot_user_ref])
    # An explicitly empty identifier is malformed, not an old receipt with no metadata.
    |> cast(fields, [:slack_audience, :slack_bot_user_ref], empty_values: [])
    |> validate_required(
      Map.keys(fields) --
        [
          :destination_thread_ref,
          :engagement_receipt,
          :repository_ref,
          :source_envelope,
          :source_item_ref,
          :slack_audience,
          :slack_bot_user_ref,
          :work_profile,
          :work_policy,
          :work_policy_digest
        ]
    )
    |> unique_constraint(:dedupe_key)
    |> check_constraint(:source_envelope, name: :ingress_inbox_source_envelope_valid)
    |> check_constraint(:engagement_receipt, name: :ingress_inbox_engagement_receipt_valid)
    |> check_constraint(:slack_audience, name: :ingress_inbox_slack_addressing_valid)
    |> check_constraint(:execution_mode, name: :ingress_inbox_execution_mode_valid)
    |> check_constraint(:work_profile, name: :ingress_inbox_work_class_profile_valid)
    |> check_constraint(:work_policy, name: :ingress_inbox_work_profile_valid)
    |> check_constraint(:status, name: :ingress_inbox_decision_matches_status)
  end

  # An oversized envelope is recorded as an explicit omission with its size, so
  # the reader can tell "the adapter never supplied one" from "it was too big".
  # Nothing here may fail the input.
  defp bounded_envelope(nil), do: nil

  defp bounded_envelope(envelope) when is_map(envelope) do
    case Ryker.CanonicalJSON.validate(envelope) do
      :ok ->
        bytes = envelope |> Ryker.CanonicalJSON.encode!() |> byte_size()

        if bytes <= @envelope_bytes,
          do: envelope,
          else: %{"omitted" => "oversized", "bytes" => bytes, "bound" => @envelope_bytes}

      {:error, _reason} ->
        %{"omitted" => "invalid"}
    end
  end

  defp bounded_envelope(_envelope), do: %{"omitted" => "invalid"}

  # A receipt is small structured evidence; anything malformed or oversized is
  # dropped rather than failing the input, and its absence reads as unrecorded.
  defp bounded_receipt(receipt) when is_map(receipt) do
    with :ok <- Ryker.CanonicalJSON.validate(receipt),
         true <- byte_size(Ryker.CanonicalJSON.encode!(receipt)) <= 8_192 do
      receipt
    else
      _ -> nil
    end
  end

  defp bounded_receipt(_receipt), do: nil

  @spec decide(Entry.t(), Decision.t(), String.t(), Ecto.UUID.t() | nil) ::
          Ecto.Changeset.t()
  def decide(%Entry{} = entry, %Decision{} = decision, decision_ref, episode_id) do
    document = Decision.document(decision)

    fields = %{
      decision_action: decision.action,
      decision_document: document,
      decision_fingerprint: Decision.fingerprint(decision),
      decision_ref: decision_ref,
      episode_id: episode_id,
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: nil,
      lease_owner: nil,
      lease_ref: nil,
      next_attempt_at: nil,
      status: :decided
    }

    entry
    |> cast(fields, Map.keys(fields))
    |> validate_required(
      Map.keys(fields) --
        [
          :episode_id,
          :last_error_code,
          :last_error_detail,
          :lease_expires_at,
          :lease_owner,
          :lease_ref,
          :next_attempt_at
        ]
    )
    |> unique_constraint(:decision_ref)
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:status, name: :ingress_inbox_decision_matches_status)
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
  end

  @spec supersede(Entry.t(), Decision.t(), String.t(), Ecto.UUID.t(), keyword()) ::
          Ecto.Changeset.t()
  def supersede(%Entry{} = entry, %Decision{} = decision, decision_ref, episode_id, details) do
    entry
    |> decide(decision, decision_ref, episode_id)
    |> put_change(:status, :superseded)
    |> put_change(:last_error_code, "stale_input_revision")
    |> put_change(
      :last_error_detail,
      inspect(details, limit: 20, printable_limit: 3_500, width: 120)
    )
    |> validate_required([:last_error_code, :last_error_detail])
    |> validate_length(:last_error_code, max: 128)
    |> validate_length(:last_error_detail, max: 4_096)
  end

  @spec claim(Entry.t(), map()) :: Ecto.Changeset.t()
  def claim(%Entry{} = entry, attributes) do
    entry
    |> cast(attributes, @execution_fields)
    |> validate_required([:attempt_count, :lease_expires_at, :lease_owner, :lease_ref])
    |> validate_number(:attempt_count, greater_than_or_equal_to: 1)
    |> validate_length(:lease_ref, max: 1_024)
    |> validate_length(:lease_owner, max: 1_024)
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
  end

  @spec renew(Entry.t(), DateTime.t()) :: Ecto.Changeset.t()
  def renew(%Entry{} = entry, lease_expires_at) do
    entry
    |> cast(%{lease_expires_at: lease_expires_at}, [:lease_expires_at])
    |> validate_required([:lease_expires_at, :lease_owner, :lease_ref])
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
  end

  @spec defer(Entry.t(), map()) :: Ecto.Changeset.t()
  def defer(%Entry{} = entry, attributes) do
    entry
    |> cast(attributes, @execution_fields)
    |> validate_required([
      :attempt_count,
      :execution_generation,
      :next_attempt_at,
      :validation_generation
    ])
    |> validate_number(:execution_generation, greater_than_or_equal_to: 1)
    |> validate_number(:validation_generation, greater_than_or_equal_to: 1)
    |> validate_length(:last_error_code, max: 128)
    |> validate_length(:last_error_detail, max: 4_096)
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
    |> check_constraint(:execution_generation, name: :ingress_inbox_execution_generation_valid)
    |> check_constraint(:validation_generation,
      name: :ingress_inbox_validation_generation_valid
    )
  end

  @spec block(Entry.t(), map()) :: Ecto.Changeset.t()
  def block(%Entry{} = entry, attributes) do
    entry
    |> cast(attributes, [
      :admission_context,
      :admission_context_fingerprint,
      :execution_generation,
      :validation_generation,
      :last_error_code,
      :last_error_detail,
      :lease_expires_at,
      :lease_owner,
      :lease_ref,
      :next_attempt_at,
      :status
    ])
    |> validate_required([:last_error_code, :last_error_detail, :status])
    |> validate_number(:execution_generation, greater_than_or_equal_to: 1)
    |> validate_number(:validation_generation, greater_than_or_equal_to: 1)
    |> validate_length(:last_error_code, max: 128)
    |> validate_length(:last_error_detail, max: 4_096)
    |> check_constraint(:status, name: :ingress_inbox_decision_matches_status)
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
  end

  @spec rearm(Entry.t()) :: Ecto.Changeset.t()
  def rearm(%Entry{} = entry) do
    entry
    |> cast(
      %{
        attempt_count: 0,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :pending
      },
      [
        :attempt_count,
        :last_error_code,
        :last_error_detail,
        :lease_expires_at,
        :lease_owner,
        :lease_ref,
        :next_attempt_at,
        :status
      ]
    )
    |> validate_required([:attempt_count, :execution_generation, :status, :validation_generation])
    |> check_constraint(:status, name: :ingress_inbox_decision_matches_status)
    |> check_constraint(:status, name: :ingress_inbox_execution_custody_valid)
  end
end
