CREATE TABLE public.coop_session_placements (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    episode_id uuid,
    worker_id text NOT NULL,
    generation bigint NOT NULL,
    lease_ref text NOT NULL,
    lease_expires_at timestamp without time zone NOT NULL,
    state text DEFAULT 'assigning'::text NOT NULL,
    requirements text NOT NULL,
    requirements_fingerprint text NOT NULL,
    last_command_id uuid,
    last_acked_event_sequence bigint DEFAULT 0 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_session_placement_identity_valid CHECK (((generation > 0) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 256)) AND (state = ANY (ARRAY['assigning'::text, 'active'::text, 'draining'::text, 'revoking'::text, 'replaced'::text, 'retired'::text])) AND (jsonb_typeof((requirements)::jsonb) = 'object'::text) AND (octet_length(requirements) <= 131072) AND (char_length(requirements_fingerprint) = 64) AND (last_acked_event_sequence >= 0)))
);


--
-- Name: coop_worker_certificates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_certificates (
    sha256 text NOT NULL,
    worker_id text NOT NULL,
    enrollment_token_id uuid,
    serial_number text NOT NULL,
    source text NOT NULL,
    issued_by text NOT NULL,
    not_before timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    revoked_at timestamp without time zone,
    revoked_by text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_certificate_valid CHECK (((sha256 ~ '^[0-9a-f]{64}$'::text) AND ((char_length(serial_number) >= 1) AND (char_length(serial_number) <= 64)) AND (source = ANY (ARRAY['enrollment'::text, 'renewal'::text, 'manual'::text])) AND ((char_length(issued_by) >= 1) AND (char_length(issued_by) <= 256)) AND (expires_at > not_before) AND (((revoked_at IS NULL) AND (revoked_by IS NULL)) OR ((revoked_at IS NOT NULL) AND ((char_length(revoked_by) >= 1) AND (char_length(revoked_by) <= 256))))))
);


--
-- Name: coop_worker_commands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_commands (
    id uuid NOT NULL,
    placement_id uuid NOT NULL,
    worker_id text NOT NULL,
    session_id uuid NOT NULL,
    placement_generation bigint NOT NULL,
    kind text NOT NULL,
    command_version bigint DEFAULT 1 NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    idempotency_key text NOT NULL,
    status text DEFAULT 'queued'::text NOT NULL,
    operation_key text,
    result text,
    error text,
    result_fingerprint text,
    delivered_at timestamp without time zone,
    acknowledged_at timestamp without time zone,
    completed_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_command_identity_valid CHECK (((placement_generation > 0) AND (command_version = 1) AND (kind = ANY (ARRAY['ensure_workspace'::text, 'create_session'::text, 'get_session'::text, 'submit_turn'::text, 'get_turn'::text, 'get_output_artifact'::text, 'get_changes'::text, 'get_changes_page'::text, 'run_review'::text, 'plan_discard'::text, 'discard_session'::text, 'get_review_patch'::text, 'validate_candidate'::text, 'cancel_turn'::text, 'fence_operation'::text, 'checkpoint_workspace'::text, 'close_session'::text, 'reconcile_operation'::text])) AND (char_length(payload_fingerprint) = 64) AND ((char_length(idempotency_key) >= 1) AND (char_length(idempotency_key) <= 512)) AND (status = ANY (ARRAY['queued'::text, 'delivered'::text, 'acknowledged'::text, 'succeeded'::text, 'failed'::text, 'uncertain'::text])))),
    CONSTRAINT coop_worker_command_result_valid CHECK ((((status = ANY (ARRAY['queued'::text, 'delivered'::text, 'acknowledged'::text])) AND (operation_key IS NULL) AND (result IS NULL) AND (error IS NULL) AND (result_fingerprint IS NULL) AND (completed_at IS NULL)) OR ((status = 'succeeded'::text) AND ((char_length(operation_key) >= 1) AND (char_length(operation_key) <= 512)) AND (result IS NOT NULL) AND (error IS NULL) AND (char_length(result_fingerprint) = 64) AND (completed_at IS NOT NULL)) OR ((status = ANY (ARRAY['failed'::text, 'uncertain'::text])) AND ((char_length(operation_key) >= 1) AND (char_length(operation_key) <= 512)) AND (result IS NULL) AND (error IS NOT NULL) AND (char_length(result_fingerprint) = 64) AND (completed_at IS NOT NULL))))
);


--
-- Name: coop_worker_enrollment_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_enrollment_tokens (
    id uuid NOT NULL,
    worker_id text NOT NULL,
    workspace_ref text NOT NULL,
    operator_ref text NOT NULL,
    token_sha256 text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    consumed_at timestamp without time zone,
    certificate_sha256 text,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_enrollment_token_valid CHECK ((((char_length(worker_id) >= 1) AND (char_length(worker_id) <= 256)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(operator_ref) >= 1) AND (char_length(operator_ref) <= 256)) AND (token_sha256 ~ '^[0-9a-f]{64}$'::text) AND ((certificate_sha256 IS NULL) OR (certificate_sha256 ~ '^[0-9a-f]{64}$'::text)) AND (((consumed_at IS NULL) AND (certificate_sha256 IS NULL)) OR ((consumed_at IS NOT NULL) AND (certificate_sha256 IS NOT NULL)))))
);


--
-- Name: coop_worker_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_events (
    id bigint NOT NULL,
    placement_id uuid NOT NULL,
    worker_id text NOT NULL,
    session_id uuid NOT NULL,
    placement_generation bigint NOT NULL,
    sequence bigint NOT NULL,
    kind text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_event_identity_valid CHECK (((placement_generation > 0) AND (sequence > 0) AND (kind = ANY (ARRAY['operation'::text, 'session'::text, 'turn'::text, 'candidate'::text, 'validation'::text, 'workspace'::text, 'checkpoint'::text, 'capacity'::text])) AND (char_length(payload_fingerprint) = 64)))
);


--
-- Name: coop_worker_events_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.coop_worker_events_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: coop_worker_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.coop_worker_events_id_seq OWNED BY public.coop_worker_events.id;


--
-- Name: coop_worker_output_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_output_transfers (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    artifact_ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_output_transfer_identity_valid CHECK ((((char_length(artifact_ref) >= 1) AND (char_length(artifact_ref) <= 256)) AND (artifact_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);


--
-- Name: coop_worker_review_patch_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_review_patch_transfers (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    artifact_id text NOT NULL,
    sha256 text NOT NULL,
    byte_size bigint NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_review_patch_identity_valid CHECK ((((char_length(artifact_id) >= 1) AND (char_length(artifact_id) <= 256)) AND (artifact_id ~ '^[A-Za-z0-9_.:-]+$'::text) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 67108864)) AND (octet_length(data) = byte_size)))
);


--
-- Name: coop_worker_workspace_checkpoints; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_worker_workspace_checkpoints (
    id uuid NOT NULL,
    command_id uuid NOT NULL,
    worker_id text NOT NULL,
    checkpoint_ref text NOT NULL,
    session_ref text NOT NULL,
    placement_generation bigint NOT NULL,
    repository_ref text NOT NULL,
    descriptor text NOT NULL,
    bundle_sha256 text NOT NULL,
    bundle_byte_size bigint NOT NULL,
    encryption_key_sha256 text CONSTRAINT coop_worker_workspace_checkpoint_encryption_key_sha256_not_null NOT NULL,
    encryption_nonce bytea NOT NULL,
    encryption_tag bytea NOT NULL,
    ciphertext bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_workspace_checkpoint_identity_valid CHECK ((((char_length(checkpoint_ref) >= 1) AND (char_length(checkpoint_ref) <= 256)) AND (checkpoint_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(session_ref) >= 1) AND (char_length(session_ref) <= 256)) AND (session_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND (placement_generation > 0) AND ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 256)) AND (repository_ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND (jsonb_typeof((descriptor)::jsonb) = 'object'::text) AND ((octet_length(descriptor) >= 1) AND (octet_length(descriptor) <= 1048576)) AND (bundle_sha256 ~ '^[0-9a-f]{64}$'::text) AND ((bundle_byte_size >= 1) AND (bundle_byte_size <= 67108864)) AND (encryption_key_sha256 ~ '^[0-9a-f]{64}$'::text) AND (octet_length(encryption_nonce) = 12) AND (octet_length(encryption_tag) = 16) AND (octet_length(ciphertext) = bundle_byte_size)))
);


--
-- Name: coop_workers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coop_workers (
    id text NOT NULL,
    workspace_ref text NOT NULL,
    certificate_sha256 text NOT NULL,
    protocol_version text,
    build_version text,
    clock_at timestamp without time zone,
    sandbox_digest text,
    policy_digests text DEFAULT '{}'::text NOT NULL,
    repositories text DEFAULT '[]'::text NOT NULL,
    capabilities text DEFAULT '[]'::text NOT NULL,
    capacity text DEFAULT '{}'::text NOT NULL,
    state text DEFAULT 'offline'::text NOT NULL,
    last_seen_at timestamp without time zone,
    drain_requested_at timestamp without time zone,
    drain_requested_by text,
    revoked_at timestamp without time zone,
    revoked_by text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT coop_worker_documents_valid CHECK (((jsonb_typeof((policy_digests)::jsonb) = 'object'::text) AND (jsonb_typeof((repositories)::jsonb) = 'array'::text) AND (jsonb_typeof((capabilities)::jsonb) = 'array'::text) AND (jsonb_typeof((capacity)::jsonb) = 'object'::text) AND (octet_length(policy_digests) <= 131072) AND (octet_length(repositories) <= 131072) AND (octet_length(capabilities) <= 131072) AND (octet_length(capacity) <= 131072))),
    CONSTRAINT coop_worker_identity_valid CHECK ((((char_length(id) >= 1) AND (char_length(id) <= 256)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND (certificate_sha256 ~ '^[0-9a-f]{64}$'::text) AND (state = ANY (ARRAY['offline'::text, 'eligible'::text, 'busy'::text, 'draining'::text, 'needs_auth'::text, 'revoked'::text])) AND ((protocol_version IS NULL) OR ((char_length(protocol_version) >= 1) AND (char_length(protocol_version) <= 64))) AND ((build_version IS NULL) OR ((char_length(build_version) >= 1) AND (char_length(build_version) <= 128))) AND ((sandbox_digest IS NULL) OR (sandbox_digest ~ '^[0-9a-f]{64}$'::text)) AND (((drain_requested_at IS NULL) AND (drain_requested_by IS NULL)) OR ((drain_requested_at IS NOT NULL) AND ((char_length(drain_requested_by) >= 1) AND (char_length(drain_requested_by) <= 256)))) AND (((state <> 'revoked'::text) AND (revoked_at IS NULL) AND (revoked_by IS NULL)) OR ((state = 'revoked'::text) AND (revoked_at IS NOT NULL) AND ((char_length(revoked_by) >= 1) AND (char_length(revoked_by) <= 256))))))
);


--
-- Name: delivery_reactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_reactions (
    id uuid NOT NULL,
    input_id uuid NOT NULL,
    decision_ref text NOT NULL,
    delivery_ref text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    source_item_ref text NOT NULL,
    document text NOT NULL,
    document_fingerprint text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    external_receipt text,
    external_receipt_fingerprint text,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    retry_generation bigint DEFAULT 0 NOT NULL,
    CONSTRAINT delivery_reaction_custody_valid CHECK (((status = ANY (ARRAY['pending'::text, 'blocked'::text, 'delivered'::text])) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (char_length(lease_ref) > 0) AND (char_length(lease_owner) > 0) AND (lease_expires_at IS NOT NULL))) AND ((status = 'pending'::text) OR (next_attempt_at IS NULL)) AND ((status <> 'blocked'::text) OR ((char_length(last_error_code) > 0) AND (char_length(last_error_detail) > 0))) AND (((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND (external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((status = 'delivered'::text) AND (external_receipt IS NOT NULL) AND (char_length(external_receipt_fingerprint) = 64) AND (delivered_at IS NOT NULL))))),
    CONSTRAINT delivery_reaction_document_valid CHECK (((jsonb_typeof((document)::jsonb) = 'object'::text) AND ((document)::jsonb ? 'emoji_name'::text) AND (((document)::jsonb - 'emoji_name'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'emoji_name'::text)) = 'string'::text) AND (char_length(((document)::jsonb ->> 'emoji_name'::text)) > 0))),
    CONSTRAINT delivery_reaction_identity_valid CHECK (((char_length(decision_ref) > 0) AND (char_length(delivery_ref) > 0) AND (char_length(transport) > 0) AND (char_length(conversation_ref) > 0) AND (char_length(source_item_ref) > 0) AND (char_length(document_fingerprint) = 64) AND (attempt_count >= 0))),
    CONSTRAINT delivery_reactions_retry_generation_check CHECK ((retry_generation >= 0))
);


--
-- Name: episode_emisar_approvals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_emisar_approvals (
    id uuid NOT NULL,
    record_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    request_id text NOT NULL,
    run_id text NOT NULL,
    operation_id text NOT NULL,
    action_id text NOT NULL,
    pack_ref text NOT NULL,
    runner_ref text NOT NULL,
    approval_url text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    status text DEFAULT 'monitoring'::text NOT NULL,
    remote_status text DEFAULT 'pending_approval'::text NOT NULL,
    run_url text,
    remote_error text,
    last_observed_at timestamp without time zone,
    terminal_at timestamp without time zone,
    resumed_at timestamp without time zone,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    next_attempt_at timestamp without time zone,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_emisar_approval_identity_valid CHECK ((((char_length(request_id) >= 1) AND (char_length(request_id) <= 80)) AND ((octet_length(run_id) >= 1) AND (octet_length(run_id) <= 200)) AND ((octet_length(operation_id) >= 1) AND (octet_length(operation_id) <= 200)) AND ((octet_length(action_id) >= 1) AND (octet_length(action_id) <= 200)) AND ((octet_length(pack_ref) >= 1) AND (octet_length(pack_ref) <= 300)) AND ((octet_length(runner_ref) >= 1) AND (octet_length(runner_ref) <= 300)) AND ((octet_length(approval_url) >= 1) AND (octet_length(approval_url) <= 2048)) AND (status = ANY (ARRAY['monitoring'::text, 'resumed'::text, 'blocked'::text])) AND (remote_status = ANY (ARRAY['pending'::text, 'pending_approval'::text, 'sent'::text, 'running'::text, 'cancelling'::text, 'success'::text, 'failed'::text, 'error'::text, 'validation_failed'::text, 'unknown_action'::text, 'cancelled'::text, 'timed_out'::text, 'refused'::text, 'denied'::text])) AND (failure_count >= 0) AND ((run_url IS NULL) OR ((octet_length(run_url) >= 1) AND (octet_length(run_url) <= 2048))) AND ((remote_error IS NULL) OR ((octet_length(remote_error) >= 1) AND (octet_length(remote_error) <= 1000))) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (((status = 'resumed'::text) AND (terminal_at IS NOT NULL) AND (resumed_at IS NOT NULL)) OR ((status <> 'resumed'::text) AND (resumed_at IS NULL))))),
    CONSTRAINT episode_emisar_approval_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'monitoring'::text) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL))))
);


--
-- Name: episode_publication_followups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_publication_followups (
    id uuid NOT NULL,
    publication_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    pr_state text DEFAULT 'open'::text NOT NULL,
    checks_state text DEFAULT 'unknown'::text NOT NULL,
    checks_total bigint DEFAULT 0 NOT NULL,
    checks_passed bigint DEFAULT 0 NOT NULL,
    checks_failed bigint DEFAULT 0 NOT NULL,
    checks_url text,
    merge_sha text,
    merged_at timestamp without time zone,
    verification_turn_ref text,
    verification_event_ref text,
    verified_at timestamp without time zone,
    next_poll_at timestamp without time zone NOT NULL,
    deadline_at timestamp without time zone NOT NULL,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    last_event_key text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    manual_check_ref text,
    verification_sequence bigint,
    CONSTRAINT episode_publication_followup_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR (((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT episode_publication_followup_state_valid CHECK (((pr_state = ANY (ARRAY['open'::text, 'closed'::text, 'merged'::text, 'stale'::text, 'expired'::text])) AND (checks_state = ANY (ARRAY['unknown'::text, 'none'::text, 'pending'::text, 'passing'::text, 'failing'::text])) AND (checks_total >= 0) AND (checks_passed >= 0) AND (checks_failed >= 0) AND ((checks_passed + checks_failed) <= checks_total) AND ((checks_url IS NULL) OR ((octet_length(checks_url) >= 1) AND (octet_length(checks_url) <= 2048))) AND ((merge_sha IS NULL) OR (merge_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$'::text)) AND ((last_event_key IS NULL) OR ((char_length(last_event_key) >= 1) AND (char_length(last_event_key) <= 128))) AND ((manual_check_ref IS NULL) OR ((char_length(manual_check_ref) >= 1) AND (char_length(manual_check_ref) <= 1024))) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (failure_count >= 0) AND (deadline_at > inserted_at) AND (((verification_turn_ref IS NULL) AND (verification_event_ref IS NULL) AND (verification_sequence IS NULL) AND (verified_at IS NULL)) OR (((char_length(verification_turn_ref) >= 1) AND (char_length(verification_turn_ref) <= 1024)) AND ((char_length(verification_event_ref) >= 1) AND (char_length(verification_event_ref) <= 1024)) AND (verification_sequence > 0)))))
);


--
-- Name: episode_publication_lifecycle_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_publication_lifecycle_events (
    id uuid NOT NULL,
    ref text NOT NULL,
    publication_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    kind text NOT NULL,
    state text NOT NULL,
    summary text NOT NULL,
    observation text NOT NULL,
    source_transport text,
    source_conversation_ref text,
    source_item_ref text,
    occurred_at timestamp without time zone NOT NULL,
    delivery_state text DEFAULT 'pending'::text NOT NULL,
    delivery_ref text NOT NULL,
    delivery_receipt text,
    delivery_receipt_fingerprint text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    wakeup_state text DEFAULT 'none'::text NOT NULL,
    CONSTRAINT episode_publication_lifecycle_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR (((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL) AND (delivery_state = 'pending'::text)))),
    CONSTRAINT episode_publication_lifecycle_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (kind = ANY (ARRAY['checks'::text, 'merged'::text, 'closed'::text, 'status'::text, 'deployment'::text, 'terraform'::text, 'verification'::text, 'deadline'::text, 'review_feedback'::text])) AND (state = ANY (ARRAY['pending'::text, 'succeeded'::text, 'failed'::text, 'stopped'::text])) AND ((octet_length(summary) >= 1) AND (octet_length(summary) <= 2048)) AND ((octet_length(observation) >= 1) AND (octet_length(observation) <= 65536)) AND (delivery_state = ANY (ARRAY['pending'::text, 'delivered'::text])) AND (wakeup_state = ANY (ARRAY['none'::text, 'pending'::text, 'admitted'::text])) AND ((char_length(delivery_ref) >= 1) AND (char_length(delivery_ref) <= 256)) AND (attempt_count >= 0) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND (((source_transport IS NULL) AND (source_conversation_ref IS NULL) AND (source_item_ref IS NULL)) OR (((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 64)) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((char_length(source_item_ref) >= 1) AND (char_length(source_item_ref) <= 1024)))) AND (((delivery_receipt IS NULL) AND (delivery_receipt_fingerprint IS NULL) AND (delivery_state = 'pending'::text)) OR ((delivery_receipt IS NOT NULL) AND (char_length(delivery_receipt_fingerprint) = 64) AND (delivery_state = 'delivered'::text)))))
);


--
-- Name: episode_publications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_publications (
    id uuid NOT NULL,
    ref text NOT NULL,
    episode_id uuid NOT NULL,
    record_id uuid NOT NULL,
    session_id uuid NOT NULL,
    repository text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    status text DEFAULT 'review_pending'::text NOT NULL,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    offer_message_ref text NOT NULL,
    review_request_ref text NOT NULL,
    review_requested_by_actor_ref text NOT NULL,
    review_requested_at timestamp without time zone NOT NULL,
    review_generation bigint DEFAULT 1 NOT NULL,
    review_expected_revision bigint,
    review_document text,
    review_fingerprint text,
    review_patch bytea,
    reviewed_at timestamp without time zone,
    review_delivery_receipt text,
    review_delivery_receipt_fingerprint text,
    approval_ref text,
    approved_by_actor_ref text,
    approved_at timestamp without time zone,
    publication_receipt text,
    publication_receipt_fingerprint text,
    published_at timestamp without time zone,
    published_delivery_receipt text,
    published_delivery_receipt_fingerprint text,
    attempt_count bigint DEFAULT 0 NOT NULL,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    github_repository text,
    branch_ref text,
    commit_sha text,
    pull_request_number bigint,
    pull_request_url text,
    CONSTRAINT episode_publication_approval_valid CHECK ((((approval_ref IS NULL) AND (approved_by_actor_ref IS NULL) AND (approved_at IS NULL) AND (status = ANY (ARRAY['review_pending'::text, 'review_ready'::text, 'reviewed'::text, 'blocked'::text]))) OR (((char_length(approval_ref) >= 1) AND (char_length(approval_ref) <= 1024)) AND ((char_length(approved_by_actor_ref) >= 1) AND (char_length(approved_by_actor_ref) <= 1024)) AND (approved_at IS NOT NULL) AND (status = ANY (ARRAY['publish_pending'::text, 'published_ready'::text, 'published'::text]))))),
    CONSTRAINT episode_publication_identity_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(repository) >= 1) AND (char_length(repository) <= 256)) AND ((char_length(title) >= 1) AND (char_length(title) <= 120)) AND ((octet_length(body) >= 1) AND (octet_length(body) <= 8000)) AND ((char_length(destination_transport) >= 1) AND (char_length(destination_transport) <= 64)) AND ((char_length(destination_conversation_ref) >= 1) AND (char_length(destination_conversation_ref) <= 1024)) AND ((destination_thread_ref IS NULL) OR ((char_length(destination_thread_ref) >= 1) AND (char_length(destination_thread_ref) <= 1024))) AND ((char_length(offer_message_ref) >= 1) AND (char_length(offer_message_ref) <= 1024)) AND ((char_length(review_request_ref) >= 1) AND (char_length(review_request_ref) <= 1024)) AND ((char_length(review_requested_by_actor_ref) >= 1) AND (char_length(review_requested_by_actor_ref) <= 1024)) AND (review_generation > 0) AND (attempt_count >= 0) AND ((review_expected_revision IS NULL) OR (review_expected_revision > 0)))),
    CONSTRAINT episode_publication_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR (((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL) AND (status = ANY (ARRAY['review_pending'::text, 'review_ready'::text, 'publish_pending'::text, 'published_ready'::text]))))),
    CONSTRAINT episode_publication_publish_valid CHECK ((((publication_receipt IS NULL) AND (publication_receipt_fingerprint IS NULL) AND (published_at IS NULL) AND (published_delivery_receipt IS NULL) AND (published_delivery_receipt_fingerprint IS NULL) AND (status <> ALL (ARRAY['published_ready'::text, 'published'::text]))) OR ((publication_receipt IS NOT NULL) AND (char_length(publication_receipt_fingerprint) = 64) AND (published_at IS NOT NULL) AND (((published_delivery_receipt IS NULL) AND (published_delivery_receipt_fingerprint IS NULL) AND (status = 'published_ready'::text)) OR ((published_delivery_receipt IS NOT NULL) AND (char_length(published_delivery_receipt_fingerprint) = 64) AND (status = 'published'::text)))))),
    CONSTRAINT episode_publication_remote_identity_valid CHECK ((((github_repository IS NULL) AND (branch_ref IS NULL) AND (commit_sha IS NULL) AND (pull_request_number IS NULL) AND (pull_request_url IS NULL)) OR ((github_repository ~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'::text) AND (branch_ref ~ '^refs/heads/[A-Za-z0-9._/-]{1,240}$'::text) AND (commit_sha ~ '^[a-f0-9]{40}([a-f0-9]{24})?$'::text) AND (pull_request_number > 0) AND ((octet_length(pull_request_url) >= 1) AND (octet_length(pull_request_url) <= 2048))))),
    CONSTRAINT episode_publication_review_valid CHECK ((((review_document IS NULL) AND (review_fingerprint IS NULL) AND (review_patch IS NULL) AND (reviewed_at IS NULL) AND (review_delivery_receipt IS NULL) AND (review_delivery_receipt_fingerprint IS NULL) AND (status = 'review_pending'::text)) OR ((review_document IS NOT NULL) AND (char_length(review_fingerprint) = 64) AND (reviewed_at IS NOT NULL) AND (((review_delivery_receipt IS NULL) AND (review_delivery_receipt_fingerprint IS NULL) AND (status = 'review_ready'::text)) OR ((review_delivery_receipt IS NOT NULL) AND (char_length(review_delivery_receipt_fingerprint) = 64) AND (status = ANY (ARRAY['reviewed'::text, 'publish_pending'::text, 'published_ready'::text, 'published'::text, 'blocked'::text])))))))
);


--
-- Name: episode_schedule_occurrences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_schedule_occurrences (
    id uuid NOT NULL,
    ref text NOT NULL,
    schedule_id uuid NOT NULL,
    scheduled_for timestamp without time zone NOT NULL,
    status text NOT NULL,
    child_episode_id uuid,
    event_ref text,
    missed_reason text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_schedule_occurrence_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (status = ANY (ARRAY['dispatched'::text, 'missed'::text])) AND (((status = 'dispatched'::text) AND (child_episode_id IS NOT NULL) AND ((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (missed_reason IS NULL)) OR ((status = 'missed'::text) AND (child_episode_id IS NULL) AND (event_ref IS NULL) AND ((octet_length(missed_reason) >= 1) AND (octet_length(missed_reason) <= 1024))))))
);


--
-- Name: episode_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_schedules (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid NOT NULL,
    source_episode_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    title text NOT NULL,
    task text NOT NULL,
    recurrence text NOT NULL,
    timezone text NOT NULL,
    catch_up text NOT NULL,
    authority text NOT NULL,
    repository text,
    destination_transport text NOT NULL,
    destination_conversation_ref text NOT NULL,
    destination_thread_ref text,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    next_occurrence_at timestamp without time zone,
    expires_at timestamp without time zone,
    failure_count bigint DEFAULT 0 NOT NULL,
    last_error text,
    lease_ref text,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    CONSTRAINT episode_schedule_lease_valid CHECK ((((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'active'::text) AND ((char_length(lease_ref) >= 1) AND (char_length(lease_ref) <= 1024)) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL)))),
    CONSTRAINT episode_schedule_revision_valid CHECK ((revision > 0)),
    CONSTRAINT episode_schedule_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (status = ANY (ARRAY['active'::text, 'paused'::text, 'completed'::text, 'expired'::text, 'deleted'::text])) AND ((octet_length(title) >= 1) AND (octet_length(title) <= 120)) AND ((octet_length(task) >= 1) AND (octet_length(task) <= 12000)) AND ((octet_length(recurrence) >= 2) AND (octet_length(recurrence) <= 4096)) AND ((char_length(timezone) >= 1) AND (char_length(timezone) <= 128)) AND (catch_up = ANY (ARRAY['latest'::text, 'skip'::text])) AND (authority = ANY (ARRAY['read_only'::text, 'repository_write'::text, 'governed_operation'::text])) AND (((authority = 'repository_write'::text) AND (repository IS NOT NULL) AND ((char_length(repository) >= 1) AND (char_length(repository) <= 256) AND (repository ~ '^[A-Za-z0-9_.:-]+$'::text))) OR ((authority = 'read_only'::text) AND ((repository IS NULL) OR ((char_length(repository) >= 1) AND (char_length(repository) <= 256) AND (repository ~ '^[A-Za-z0-9_.:-]+$'::text)))) OR ((authority = 'governed_operation'::text) AND (repository IS NULL))) AND ((char_length(destination_transport) >= 1) AND (char_length(destination_transport) <= 64)) AND ((char_length(destination_conversation_ref) >= 1) AND (char_length(destination_conversation_ref) <= 1024)) AND ((destination_thread_ref IS NULL) OR ((char_length(destination_thread_ref) >= 1) AND (char_length(destination_thread_ref) <= 1024))) AND ((char_length(confirmed_by_actor_ref) >= 1) AND (char_length(confirmed_by_actor_ref) <= 1024)) AND ((char_length(confirmation_ref) >= 1) AND (char_length(confirmation_ref) <= 1024)) AND (failure_count >= 0) AND ((last_error IS NULL) OR ((octet_length(last_error) >= 1) AND (octet_length(last_error) <= 4096))) AND ((expires_at IS NULL) OR (expires_at > confirmed_at)) AND (((status = ANY (ARRAY['active'::text, 'paused'::text])) AND (next_occurrence_at IS NOT NULL)) OR (status = ANY (ARRAY['completed'::text, 'expired'::text, 'deleted'::text])))))
);


--
-- Name: episode_state_record_responses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_state_record_responses (
    id uuid NOT NULL,
    record_id uuid NOT NULL,
    inbox_entry_id uuid NOT NULL,
    response_ref text NOT NULL,
    actor_ref text NOT NULL,
    choice_index integer NOT NULL,
    choice text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT episode_state_record_response_valid CHECK ((((char_length(response_ref) >= 1) AND (char_length(response_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND ((choice_index >= 0) AND (choice_index <= 9)) AND ((char_length(choice) >= 1) AND (char_length(choice) <= 240))))
);


--
-- Name: episode_state_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.episode_state_records (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    ref text NOT NULL,
    operation_id text NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'open'::text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    continuation text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    confirmed_episode_id uuid,
    confirmation_ref text,
    confirmed_by_actor_ref text,
    confirmed_at timestamp without time zone,
    subject_ref text,
    sequence bigint NOT NULL,
    CONSTRAINT episode_state_record_confirmation_valid CHECK ((((status = 'confirmed'::text) AND (char_length(confirmation_ref) > 0) AND (char_length(confirmed_by_actor_ref) > 0) AND (confirmed_at IS NOT NULL) AND (((kind = ANY (ARRAY['schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'automation_change_offer'::text, 'slack_post_offer'::text])) AND (confirmed_episode_id IS NULL)) OR ((kind <> ALL (ARRAY['schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'automation_change_offer'::text, 'slack_post_offer'::text])) AND (confirmed_episode_id IS NOT NULL)))) OR ((status <> 'confirmed'::text) AND (confirmed_episode_id IS NULL) AND (confirmation_ref IS NULL) AND (confirmed_by_actor_ref IS NULL) AND (confirmed_at IS NULL)))),
    CONSTRAINT episode_state_record_identity_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(operation_id) >= 1) AND (char_length(operation_id) <= 80)) AND (kind = ANY (ARRAY['task_offer'::text, 'publication_offer'::text, 'schedule_offer'::text, 'memory_offer'::text, 'preference_offer'::text, 'guidance_offer'::text, 'standing_assignment_offer'::text, 'slack_post_offer'::text, 'input_request'::text, 'event_wait'::text, 'emisar_approval'::text, 'evidence'::text, 'coverage'::text, 'finding'::text, 'progress'::text, 'goal'::text, 'goal_state'::text, 'alert_assessment'::text, 'automation_change_offer'::text])) AND (status = ANY (ARRAY['open'::text, 'confirmed'::text, 'answered'::text, 'dismissed'::text, 'superseded'::text])) AND (char_length(payload_fingerprint) = 64) AND (((kind = ANY (ARRAY['goal'::text, 'goal_state'::text])) AND ((char_length(subject_ref) >= 1) AND (char_length(subject_ref) <= 120))) OR ((kind <> ALL (ARRAY['goal'::text, 'goal_state'::text])) AND (subject_ref IS NULL)))))
);


--
-- Name: episode_state_records_sequence_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.episode_state_records_sequence_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: episode_state_records_sequence_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.episode_state_records_sequence_seq OWNED BY public.episode_state_records.sequence;


--
-- Name: input_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.input_artifacts (
    id uuid NOT NULL,
    ref text NOT NULL,
    source_kind text NOT NULL,
    source_ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT input_artifact_identity_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 128)) AND (source_kind ~ '^[a-z0-9_.-]+$'::text) AND ((char_length(source_kind) >= 1) AND (char_length(source_kind) <= 64)) AND ((char_length(source_ref) >= 1) AND (char_length(source_ref) <= 1024)) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text, 'text/plain'::text, 'text/markdown'::text, 'text/csv'::text, 'application/json'::text, 'application/yaml'::text, 'application/x-yaml'::text, 'application/pdf'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);


--
-- Name: operational_memory_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operational_memory_entries (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    visibility text NOT NULL,
    subject text NOT NULL,
    payload text NOT NULL,
    payload_fingerprint text NOT NULL,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    source_transport text NOT NULL,
    source_conversation_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    recall_count bigint DEFAULT 0 NOT NULL,
    last_recalled_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT operational_memory_entry_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (kind = ANY (ARRAY['alias'::text, 'repository_binding'::text, 'evidence_route'::text, 'entity_relationship'::text])) AND (status = ANY (ARRAY['active'::text, 'superseded'::text, 'deleted'::text, 'expired'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND (scope_kind = ANY (ARRAY['conversation'::text, 'repository'::text, 'workspace'::text])) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND (visibility = ANY (ARRAY['conversation'::text, 'workspace'::text])) AND ((char_length(subject) >= 1) AND (char_length(subject) <= 120)) AND ((octet_length(payload) >= 2) AND (octet_length(payload) <= 32768)) AND (char_length(payload_fingerprint) = 64) AND ((char_length(confirmed_by_actor_ref) >= 1) AND (char_length(confirmed_by_actor_ref) <= 1024)) AND ((char_length(confirmation_ref) >= 1) AND (char_length(confirmation_ref) <= 1024)) AND ((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 1024)) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((source_thread_ref IS NULL) OR ((char_length(source_thread_ref) >= 1) AND (char_length(source_thread_ref) <= 1024))) AND ((char_length(source_message_ref) >= 1) AND (char_length(source_message_ref) <= 1024)) AND (expires_at > confirmed_at) AND (recall_count >= 0) AND (((scope_kind = 'conversation'::text) AND (visibility = 'conversation'::text)) OR (scope_kind = 'repository'::text) OR ((scope_kind = 'workspace'::text) AND (visibility = 'workspace'::text)))))
);


--
-- Name: operator_behaviors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operator_behaviors (
    id uuid NOT NULL,
    ref text NOT NULL,
    offer_record_id uuid NOT NULL,
    kind text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    identity_key text NOT NULL,
    payload text NOT NULL,
    confirmed_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    confirmed_at timestamp without time zone NOT NULL,
    source_transport text NOT NULL,
    source_conversation_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    expires_at timestamp without time zone,
    use_count bigint DEFAULT 0 NOT NULL,
    last_used_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    CONSTRAINT operator_behavior_revision_valid CHECK ((revision > 0)),
    CONSTRAINT operator_behavior_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (kind = ANY (ARRAY['preference'::text, 'guidance'::text, 'standing_assignment'::text])) AND (status = ANY (ARRAY['active'::text, 'disabled'::text, 'superseded'::text, 'deleted'::text, 'expired'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 1024)) AND (scope_kind = ANY (ARRAY['workspace'::text, 'conversation'::text, 'repository'::text, 'operator'::text])) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND ((char_length(identity_key) >= 1) AND (char_length(identity_key) <= 256)) AND ((octet_length(payload) >= 2) AND (octet_length(payload) <= 32768)) AND ((char_length(confirmed_by_actor_ref) >= 1) AND (char_length(confirmed_by_actor_ref) <= 1024)) AND ((char_length(confirmation_ref) >= 1) AND (char_length(confirmation_ref) <= 1024)) AND ((char_length(source_transport) >= 1) AND (char_length(source_transport) <= 1024)) AND ((char_length(source_conversation_ref) >= 1) AND (char_length(source_conversation_ref) <= 1024)) AND ((source_thread_ref IS NULL) OR ((char_length(source_thread_ref) >= 1) AND (char_length(source_thread_ref) <= 1024))) AND ((char_length(source_message_ref) >= 1) AND (char_length(source_message_ref) <= 1024)) AND ((expires_at IS NULL) OR (expires_at > confirmed_at)) AND (use_count >= 0)))
);


--
-- Name: platform_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.platform_actions (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    action_ref text NOT NULL,
    host_slot text NOT NULL,
    tool text NOT NULL,
    kind text NOT NULL,
    transport text NOT NULL,
    conversation_ref text NOT NULL,
    thread_ref text,
    source_item_ref text,
    document text NOT NULL,
    intent_fingerprint text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    retry_generation bigint DEFAULT 0 NOT NULL,
    lease_ref uuid,
    lease_owner text,
    lease_expires_at timestamp without time zone,
    next_attempt_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    external_receipt text,
    external_receipt_fingerprint text,
    delivered_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT platform_actions_custody_valid CHECK (((status = ANY (ARRAY['pending'::text, 'blocked'::text, 'delivered'::text])) AND (((lease_ref IS NULL) AND (lease_owner IS NULL) AND (lease_expires_at IS NULL)) OR ((status = 'pending'::text) AND (lease_ref IS NOT NULL) AND ((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_expires_at IS NOT NULL))) AND ((status = 'pending'::text) OR (next_attempt_at IS NULL)) AND ((status <> 'blocked'::text) OR (((char_length(last_error_code) >= 1) AND (char_length(last_error_code) <= 128)) AND ((char_length(last_error_detail) >= 1) AND (char_length(last_error_detail) <= 4096)))) AND (((status = ANY (ARRAY['pending'::text, 'blocked'::text])) AND (external_receipt IS NULL) AND (external_receipt_fingerprint IS NULL) AND (delivered_at IS NULL)) OR ((status = 'delivered'::text) AND (external_receipt IS NOT NULL) AND (char_length(external_receipt_fingerprint) = 64) AND (delivered_at IS NOT NULL))))),
    CONSTRAINT platform_actions_document_valid CHECK (((jsonb_typeof((document)::jsonb) = 'object'::text) AND (((kind = 'message'::text) AND (source_item_ref IS NULL) AND ((document)::jsonb ? 'message'::text) AND (((document)::jsonb - 'message'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'message'::text)) = 'string'::text) AND ((char_length(((document)::jsonb ->> 'message'::text)) >= 1) AND (char_length(((document)::jsonb ->> 'message'::text)) <= 20000))) OR ((kind = 'reaction'::text) AND (source_item_ref IS NOT NULL) AND ((document)::jsonb ? 'emoji_name'::text) AND ((document)::jsonb ? 'action'::text) AND ((((document)::jsonb - 'emoji_name'::text) - 'action'::text) = '{}'::jsonb) AND (jsonb_typeof(((document)::jsonb -> 'emoji_name'::text)) = 'string'::text) AND ((char_length(((document)::jsonb ->> 'emoji_name'::text)) >= 1) AND (char_length(((document)::jsonb ->> 'emoji_name'::text)) <= 100)) AND (((document)::jsonb ->> 'action'::text) = ANY (ARRAY['add'::text, 'remove'::text])))))),
    CONSTRAINT platform_actions_identity_valid CHECK ((((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 256)) AND ((char_length(host_slot) >= 1) AND (char_length(host_slot) <= 256)) AND (tool = ANY (ARRAY['set_slack_reaction'::text, 'post_slack_message'::text, 'set_github_reaction'::text])) AND (kind = ANY (ARRAY['message'::text, 'reaction'::text])) AND ((char_length(transport) >= 1) AND (char_length(transport) <= 1024)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND ((thread_ref IS NULL) OR ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024))) AND ((source_item_ref IS NULL) OR ((char_length(source_item_ref) >= 1) AND (char_length(source_item_ref) <= 1024))) AND (char_length(intent_fingerprint) = 64) AND (attempt_count >= 0) AND (retry_generation >= 0)))
);


--
-- Name: retention_operator_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.retention_operator_actions (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    action_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    action text NOT NULL,
    previous_status text NOT NULL,
    result_status text NOT NULL,
    previous_plan_fingerprint text,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT retention_operator_action_valid CHECK ((((char_length(action_ref) >= 1) AND (char_length(action_ref) <= 1024)) AND (char_length(request_fingerprint) = 64) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (action = ANY (ARRAY['rearm'::text, 'discard_unmerged'::text])) AND (previous_status = ANY (ARRAY['blocked'::text, 'retained'::text])) AND (result_status = ANY (ARRAY['close_pending'::text, 'plan_pending'::text, 'discard_pending'::text])) AND ((previous_plan_fingerprint IS NULL) OR (char_length(previous_plan_fingerprint) = 64))))
);


--
-- Name: slack_channel_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_channel_configurations (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    participation text NOT NULL,
    repository_ref text NOT NULL,
    alert_policy text NOT NULL,
    invite_user_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    invite_user_group_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    actor_ref text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    saved_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_configuration_valid CHECK (((participation = ANY (ARRAY['mentions'::text, 'proactive'::text, 'shadow'::text])) AND (alert_policy = ANY (ARRAY['reply'::text, 'offer'::text, 'automatic'::text])) AND (revision > 0) AND (char_length(repository_ref) > 0) AND (char_length(actor_ref) > 0)))
);


--
-- Name: slack_channel_membership_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_channel_membership_events (
    id uuid NOT NULL,
    membership_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    actor_ref text,
    kind text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_membership_event_valid CHECK (((kind = ANY (ARRAY['joined'::text, 'left'::text, 'deleted'::text])) AND (char_length(event_fingerprint) = 64)))
);


--
-- Name: slack_channel_memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_channel_memberships (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    status text NOT NULL,
    generation bigint DEFAULT 1 NOT NULL,
    joined_at timestamp without time zone,
    left_at timestamp without time zone,
    deleted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_membership_valid CHECK (((generation > 0) AND (status = ANY (ARRAY['joined'::text, 'left'::text, 'deleted'::text])) AND (((status = 'joined'::text) AND (joined_at IS NOT NULL) AND (left_at IS NULL) AND (deleted_at IS NULL)) OR ((status = 'left'::text) AND (joined_at IS NOT NULL) AND (left_at IS NOT NULL) AND (deleted_at IS NULL)) OR ((status = 'deleted'::text) AND (deleted_at IS NOT NULL)))))
);


--
-- Name: slack_channel_setting_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_channel_setting_audit (
    id uuid NOT NULL,
    event_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    workspace_ref text NOT NULL,
    conversation_ref text NOT NULL,
    actor_ref text NOT NULL,
    outcome text NOT NULL,
    detail text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_setting_audit_valid CHECK ((((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (char_length(request_fingerprint) = 64) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(conversation_ref) >= 1) AND (char_length(conversation_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND (outcome = 'updated'::text) AND ((octet_length(detail) >= 2) AND (octet_length(detail) <= 4096))))
);


--
-- Name: slack_channel_setting_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_channel_setting_overrides (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    scope_kind text NOT NULL,
    scope_ref text NOT NULL,
    setting text NOT NULL,
    value boolean NOT NULL,
    actor_ref text NOT NULL,
    event_ref text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_channel_setting_override_valid CHECK ((((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND (scope_kind = ANY (ARRAY['channel'::text, 'workspace'::text])) AND ((char_length(scope_ref) >= 1) AND (char_length(scope_ref) <= 1024)) AND (setting = ANY (ARRAY['proactive'::text, 'shadow'::text])) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND ((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (revision > 0)))
);


--
-- Name: slack_configuration_actions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_configuration_actions (
    id uuid NOT NULL,
    session_id uuid NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    actor_ref text NOT NULL,
    action text NOT NULL,
    outcome text NOT NULL,
    session_revision bigint NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_configuration_action_valid CHECK (((char_length(event_fingerprint) = 64) AND (session_revision > 0) AND (char_length(outcome) > 0)))
);


--
-- Name: slack_configuration_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_configuration_sessions (
    id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    membership_generation bigint NOT NULL,
    start_event_ref text NOT NULL,
    start_fingerprint text NOT NULL,
    initiator_ref text,
    step text NOT NULL,
    status text NOT NULL,
    draft text NOT NULL,
    revision bigint DEFAULT 1 NOT NULL,
    root_message_ref text,
    response_thread_ref text,
    current_message_ref text,
    expires_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_configuration_session_valid CHECK (((step = ANY (ARRAY['participation'::text, 'repository'::text, 'alerts'::text, 'audience'::text, 'confirm'::text])) AND (status = ANY (ARRAY['asking'::text, 'confirming'::text, 'saved'::text, 'cancelled'::text, 'expired'::text])) AND (membership_generation > 0) AND (revision > 0) AND (char_length(start_fingerprint) = 64) AND (jsonb_typeof((draft)::jsonb) = 'object'::text) AND ((status <> 'confirming'::text) OR (step = 'confirm'::text))))
);


--
-- Name: slack_incident_room_lifecycle_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_incident_room_lifecycle_events (
    id uuid NOT NULL,
    room_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    event_ref text NOT NULL,
    event_fingerprint text NOT NULL,
    kind text NOT NULL,
    occurred_at timestamp without time zone NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_incident_room_lifecycle_event_valid CHECK (((kind = ANY (ARRAY['joined'::text, 'left'::text, 'archived'::text, 'unarchived'::text, 'deleted'::text, 'observed_active'::text, 'observed_archived'::text, 'observed_unavailable'::text])) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (char_length(event_fingerprint) = 64)))
);


--
-- Name: slack_incident_rooms; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_incident_rooms (
    id uuid NOT NULL,
    ref text NOT NULL,
    record_id uuid NOT NULL,
    source_episode_id uuid NOT NULL,
    episode_id uuid,
    status text NOT NULL,
    workspace_ref text NOT NULL,
    bot_user_ref text NOT NULL,
    source_channel_ref text NOT NULL,
    source_thread_ref text,
    source_message_ref text NOT NULL,
    requested_by_actor_ref text NOT NULL,
    confirmation_ref text NOT NULL,
    requested_at timestamp without time zone NOT NULL,
    policy text NOT NULL,
    policy_digest text NOT NULL,
    repository_ref text NOT NULL,
    title text NOT NULL,
    prompt text NOT NULL,
    channel_name text NOT NULL,
    private boolean NOT NULL,
    channel_ref text,
    channel_state text DEFAULT 'pending'::text NOT NULL,
    reconciled_channel_state text DEFAULT 'pending'::text NOT NULL,
    channel_state_event_ref text,
    channel_state_changed_at timestamp without time zone,
    channel_checked_at timestamp without time zone,
    root_message_ref text,
    root_card_fingerprint text,
    root_card_ui_revision bigint DEFAULT 0 NOT NULL,
    root_card_checked_at timestamp without time zone,
    handoff_message_ref text,
    topic text NOT NULL,
    invite_user_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    invite_user_group_refs text[] DEFAULT ARRAY[]::text[] NOT NULL,
    audience_prepared_at timestamp without time zone,
    topic_prepared_at timestamp without time zone,
    root_pinned_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_incident_room_valid CHECK (((status = ANY (ARRAY['requested'::text, 'ready'::text, 'blocked'::text, 'closed'::text])) AND (channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text])) AND (reconciled_channel_state = ANY (ARRAY['pending'::text, 'active'::text, 'archived'::text, 'deleted'::text, 'unavailable'::text])) AND ((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(policy) >= 1) AND (char_length(policy) <= 256)) AND (char_length(policy_digest) = 64) AND ((char_length(repository_ref) >= 1) AND (char_length(repository_ref) <= 256)) AND ((char_length(title) >= 1) AND (char_length(title) <= 200)) AND ((char_length(prompt) >= 1) AND (char_length(prompt) <= 4000)) AND ((char_length(channel_name) >= 1) AND (char_length(channel_name) <= 80)) AND ((char_length(topic) >= 1) AND (char_length(topic) <= 250)) AND (attempt_count >= 0) AND (root_card_ui_revision >= 0) AND ((root_card_fingerprint IS NULL) OR (char_length(root_card_fingerprint) = 64)) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR ((status = ANY (ARRAY['requested'::text, 'ready'::text])) AND (char_length(lease_owner) > 0) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL))) AND ((status = ANY (ARRAY['requested'::text, 'ready'::text])) OR (next_attempt_at IS NULL)) AND (((channel_ref IS NULL) AND (channel_state = 'pending'::text)) OR ((channel_ref IS NOT NULL) AND (channel_state <> 'pending'::text))) AND ((status <> 'ready'::text) OR ((episode_id IS NOT NULL) AND (channel_ref IS NOT NULL) AND (root_message_ref IS NOT NULL) AND (root_card_fingerprint IS NOT NULL) AND (root_card_ui_revision > 0) AND (handoff_message_ref IS NOT NULL) AND (audience_prepared_at IS NOT NULL) AND (topic_prepared_at IS NOT NULL) AND (root_pinned_at IS NOT NULL)))))
);


--
-- Name: slack_interaction_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_interaction_audit (
    id uuid NOT NULL,
    event_ref text NOT NULL,
    request_fingerprint text NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text,
    message_ref text NOT NULL,
    actor_ref text NOT NULL,
    action_id text NOT NULL,
    action_value_digest text NOT NULL,
    outcome text NOT NULL,
    repaint_status text NOT NULL,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    occurred_at timestamp without time zone NOT NULL,
    repainted_at timestamp without time zone,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_interaction_audit_valid CHECK ((((char_length(event_ref) >= 1) AND (char_length(event_ref) <= 1024)) AND (char_length(request_fingerprint) = 64) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((thread_ref IS NULL) OR ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024))) AND ((char_length(message_ref) >= 1) AND (char_length(message_ref) <= 1024)) AND ((char_length(actor_ref) >= 1) AND (char_length(actor_ref) <= 1024)) AND ((char_length(action_id) >= 1) AND (char_length(action_id) <= 256)) AND (char_length(action_value_digest) = 64) AND (outcome = ANY (ARRAY['denied'::text, 'invalid'::text])) AND (repaint_status = ANY (ARRAY['none'::text, 'pending'::text, 'settled'::text, 'blocked'::text])) AND (((outcome = 'denied'::text) AND (repaint_status = 'none'::text)) OR (outcome = 'invalid'::text)) AND (attempt_count >= 0) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR (((char_length(lease_owner) >= 1) AND (char_length(lease_owner) <= 1024)) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL))) AND ((repainted_at IS NULL) OR (repaint_status = 'settled'::text))))
);


--
-- Name: slack_source_audits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_source_audits (
    id uuid NOT NULL,
    episode_id uuid NOT NULL,
    turn_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text,
    requester_ref text NOT NULL,
    tool text NOT NULL,
    capability text NOT NULL,
    request_fingerprint text NOT NULL,
    source_fingerprint text,
    range_fingerprint text NOT NULL,
    authorized boolean NOT NULL,
    result_count bigint NOT NULL,
    complete boolean NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_source_audits_valid CHECK ((((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((channel_ref IS NULL) OR ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256))) AND ((char_length(requester_ref) >= 1) AND (char_length(requester_ref) <= 1024)) AND (tool = ANY (ARRAY['list_slack_channels'::text, 'search_slack'::text, 'read_slack_source'::text])) AND ((char_length(capability) >= 1) AND (char_length(capability) <= 128)) AND (char_length(request_fingerprint) = 64) AND ((source_fingerprint IS NULL) OR (char_length(source_fingerprint) = 64)) AND (char_length(range_fingerprint) = 64) AND ((result_count >= 0) AND (result_count <= 10000))))
);


--
-- Name: slack_task_cards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.slack_task_cards (
    id uuid NOT NULL,
    ref text NOT NULL,
    record_id uuid NOT NULL,
    episode_id uuid NOT NULL,
    workspace_ref text NOT NULL,
    channel_ref text NOT NULL,
    thread_ref text NOT NULL,
    message_ref text NOT NULL,
    card_fingerprint text,
    rendered_publication_offer_ref text,
    card_ui_revision bigint DEFAULT 0 NOT NULL,
    card_checked_at timestamp without time zone,
    attempt_count bigint DEFAULT 0 NOT NULL,
    next_attempt_at timestamp without time zone,
    lease_owner text,
    lease_ref uuid,
    lease_expires_at timestamp without time zone,
    last_error_code text,
    last_error_detail text,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT slack_task_card_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(workspace_ref) >= 1) AND (char_length(workspace_ref) <= 256)) AND ((char_length(channel_ref) >= 1) AND (char_length(channel_ref) <= 256)) AND ((char_length(thread_ref) >= 1) AND (char_length(thread_ref) <= 1024)) AND ((char_length(message_ref) >= 1) AND (char_length(message_ref) <= 1024)) AND (card_ui_revision >= 0) AND ((card_fingerprint IS NULL) OR (char_length(card_fingerprint) = 64)) AND ((rendered_publication_offer_ref IS NULL) OR ((char_length(rendered_publication_offer_ref) >= 1) AND (char_length(rendered_publication_offer_ref) <= 256))) AND (attempt_count >= 0) AND (((lease_owner IS NULL) AND (lease_ref IS NULL) AND (lease_expires_at IS NULL)) OR ((char_length(lease_owner) > 0) AND (lease_ref IS NOT NULL) AND (lease_expires_at IS NOT NULL)))))
);


--
-- Name: standing_assignment_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.standing_assignment_runs (
    id uuid NOT NULL,
    ref text NOT NULL,
    assignment_id uuid NOT NULL,
    source_input_ref text NOT NULL,
    source_event_ref text NOT NULL,
    outcome text NOT NULL,
    decision_action text,
    decision_ref text,
    episode_id uuid,
    inserted_at timestamp without time zone NOT NULL,
    CONSTRAINT standing_assignment_run_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND ((char_length(source_input_ref) >= 1) AND (char_length(source_input_ref) <= 1024)) AND ((char_length(source_event_ref) >= 1) AND (char_length(source_event_ref) <= 1024)) AND (outcome = ANY (ARRAY['pending'::text, 'decided'::text, 'superseded'::text])) AND (((outcome = 'pending'::text) AND (decision_action IS NULL) AND (decision_ref IS NULL) AND (episode_id IS NULL)) OR ((outcome = ANY (ARRAY['decided'::text, 'superseded'::text])) AND (decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text, 'react'::text, 'ignore'::text])) AND ((char_length(decision_ref) >= 1) AND (char_length(decision_ref) <= 1024)) AND (((decision_action = ANY (ARRAY['start_episode'::text, 'continue_episode'::text, 'reply'::text])) AND (episode_id IS NOT NULL)) OR ((decision_action = ANY (ARRAY['react'::text, 'ignore'::text])) AND (episode_id IS NULL)))))))
);


--
-- Name: work_output_artifacts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.work_output_artifacts (
    id uuid NOT NULL,
    turn_id uuid NOT NULL,
    ref text NOT NULL,
    name text NOT NULL,
    media_type text NOT NULL,
    sha256 text NOT NULL,
    byte_size integer NOT NULL,
    data bytea NOT NULL,
    inserted_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    CONSTRAINT work_output_artifact_identity_valid CHECK ((((char_length(ref) >= 1) AND (char_length(ref) <= 256)) AND (ref ~ '^[A-Za-z0-9_.:-]+$'::text) AND ((char_length(name) >= 1) AND (char_length(name) <= 255)) AND (media_type = ANY (ARRAY['image/png'::text, 'image/jpeg'::text, 'image/webp'::text, 'image/gif'::text])) AND (sha256 ~ '^[0-9a-f]{64}$'::text) AND ((byte_size >= 1) AND (byte_size <= 8388608)) AND (octet_length(data) = byte_size)))
);


--
-- Name: coop_worker_events id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_events ALTER COLUMN id SET DEFAULT nextval('public.coop_worker_events_id_seq'::regclass);


--
-- Name: episode_state_records sequence; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_records ALTER COLUMN sequence SET DEFAULT nextval('public.episode_state_records_sequence_seq'::regclass);


--
-- Name: coop_session_placements coop_session_placements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_certificates coop_worker_certificates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_pkey PRIMARY KEY (sha256);


--
-- Name: coop_worker_commands coop_worker_commands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_commands
    ADD CONSTRAINT coop_worker_commands_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_enrollment_tokens coop_worker_enrollment_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_enrollment_tokens
    ADD CONSTRAINT coop_worker_enrollment_tokens_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_events coop_worker_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_events
    ADD CONSTRAINT coop_worker_events_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_output_transfers coop_worker_output_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_output_transfers
    ADD CONSTRAINT coop_worker_output_transfers_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_review_patch_transfers coop_worker_review_patch_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_review_patch_transfers
    ADD CONSTRAINT coop_worker_review_patch_transfers_pkey PRIMARY KEY (id);


--
-- Name: coop_worker_workspace_checkpoints coop_worker_workspace_checkpoints_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_workspace_checkpoints
    ADD CONSTRAINT coop_worker_workspace_checkpoints_pkey PRIMARY KEY (id);


--
-- Name: coop_workers coop_workers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_workers
    ADD CONSTRAINT coop_workers_pkey PRIMARY KEY (id);


--
-- Name: delivery_reactions delivery_reactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_reactions
    ADD CONSTRAINT delivery_reactions_pkey PRIMARY KEY (id);


--
-- Name: episode_emisar_approvals episode_emisar_approvals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_pkey PRIMARY KEY (id);


--
-- Name: episode_publication_followups episode_publication_followups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followups_pkey PRIMARY KEY (id);


--
-- Name: episode_publication_lifecycle_events episode_publication_lifecycle_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_events_pkey PRIMARY KEY (id);


--
-- Name: episode_publications episode_publications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_pkey PRIMARY KEY (id);


--
-- Name: episode_schedule_occurrences episode_schedule_occurrences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_pkey PRIMARY KEY (id);


--
-- Name: episode_schedules episode_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_pkey PRIMARY KEY (id);


--
-- Name: episode_state_record_responses episode_state_record_responses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_pkey PRIMARY KEY (id);


--
-- Name: episode_state_records episode_state_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_pkey PRIMARY KEY (id);


--
-- Name: input_artifacts input_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.input_artifacts
    ADD CONSTRAINT input_artifacts_pkey PRIMARY KEY (id);


--
-- Name: operational_memory_entries operational_memory_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_memory_entries
    ADD CONSTRAINT operational_memory_entries_pkey PRIMARY KEY (id);


--
-- Name: operator_behaviors operator_behaviors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_behaviors
    ADD CONSTRAINT operator_behaviors_pkey PRIMARY KEY (id);


--
-- Name: platform_actions platform_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_pkey PRIMARY KEY (id);


--
-- Name: retention_operator_actions retention_operator_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retention_operator_actions
    ADD CONSTRAINT retention_operator_actions_pkey PRIMARY KEY (id);


--
-- Name: slack_channel_configurations slack_channel_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_configurations
    ADD CONSTRAINT slack_channel_configurations_pkey PRIMARY KEY (id);


--
-- Name: slack_channel_membership_events slack_channel_membership_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_membership_events
    ADD CONSTRAINT slack_channel_membership_events_pkey PRIMARY KEY (id);


--
-- Name: slack_channel_memberships slack_channel_memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_memberships
    ADD CONSTRAINT slack_channel_memberships_pkey PRIMARY KEY (id);


--
-- Name: slack_channel_setting_audit slack_channel_setting_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_setting_audit
    ADD CONSTRAINT slack_channel_setting_audit_pkey PRIMARY KEY (id);


--
-- Name: slack_channel_setting_overrides slack_channel_setting_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_setting_overrides
    ADD CONSTRAINT slack_channel_setting_overrides_pkey PRIMARY KEY (id);


--
-- Name: slack_configuration_actions slack_configuration_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_configuration_actions
    ADD CONSTRAINT slack_configuration_actions_pkey PRIMARY KEY (id);


--
-- Name: slack_configuration_sessions slack_configuration_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_configuration_sessions
    ADD CONSTRAINT slack_configuration_sessions_pkey PRIMARY KEY (id);


--
-- Name: slack_incident_room_lifecycle_events slack_incident_room_lifecycle_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_room_lifecycle_events
    ADD CONSTRAINT slack_incident_room_lifecycle_events_pkey PRIMARY KEY (id);


--
-- Name: slack_incident_rooms slack_incident_rooms_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_pkey PRIMARY KEY (id);


--
-- Name: slack_interaction_audit slack_interaction_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_interaction_audit
    ADD CONSTRAINT slack_interaction_audit_pkey PRIMARY KEY (id);


--
-- Name: slack_source_audits slack_source_audits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_pkey PRIMARY KEY (id);


--
-- Name: slack_task_cards slack_task_cards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_pkey PRIMARY KEY (id);


--
-- Name: standing_assignment_runs standing_assignment_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_pkey PRIMARY KEY (id);


--
-- Name: work_output_artifacts work_output_artifacts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_output_artifacts
    ADD CONSTRAINT work_output_artifacts_pkey PRIMARY KEY (id);


--
-- Name: coop_session_placements_command_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_session_placements_command_identity ON public.coop_session_placements USING btree (id, worker_id, session_id, generation);


--
-- Name: coop_session_placements_one_current; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_session_placements_one_current ON public.coop_session_placements USING btree (session_id) WHERE (state = ANY (ARRAY['assigning'::text, 'active'::text, 'draining'::text, 'revoking'::text]));


--
-- Name: coop_session_placements_session_id_generation_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_session_placements_session_id_generation_index ON public.coop_session_placements USING btree (session_id, generation);


--
-- Name: coop_session_placements_worker_id_state_lease_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_session_placements_worker_id_state_lease_expires_at_index ON public.coop_session_placements USING btree (worker_id, state, lease_expires_at);


--
-- Name: coop_worker_certificates_worker_id_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_certificates_worker_id_expires_at_index ON public.coop_worker_certificates USING btree (worker_id, expires_at);


--
-- Name: coop_worker_commands_id_worker_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_commands_id_worker_id_index ON public.coop_worker_commands USING btree (id, worker_id);


--
-- Name: coop_worker_commands_idempotency_key_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_commands_idempotency_key_index ON public.coop_worker_commands USING btree (idempotency_key);


--
-- Name: coop_worker_commands_placement_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_commands_placement_id_inserted_at_index ON public.coop_worker_commands USING btree (placement_id, inserted_at);


--
-- Name: coop_worker_commands_worker_id_status_inserted_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_commands_worker_id_status_inserted_at_id_index ON public.coop_worker_commands USING btree (worker_id, status, inserted_at, id);


--
-- Name: coop_worker_enrollment_tokens_token_sha256_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_enrollment_tokens_token_sha256_index ON public.coop_worker_enrollment_tokens USING btree (token_sha256);


--
-- Name: coop_worker_enrollment_tokens_worker_id_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_enrollment_tokens_worker_id_expires_at_index ON public.coop_worker_enrollment_tokens USING btree (worker_id, expires_at);


--
-- Name: coop_worker_events_placement_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_events_placement_id_sequence_index ON public.coop_worker_events USING btree (placement_id, sequence);


--
-- Name: coop_worker_events_session_id_placement_generation_sequence_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_events_session_id_placement_generation_sequence_ind ON public.coop_worker_events USING btree (session_id, placement_generation, sequence);


--
-- Name: coop_worker_output_transfers_command_id_artifact_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_output_transfers_command_id_artifact_ref_index ON public.coop_worker_output_transfers USING btree (command_id, artifact_ref);


--
-- Name: coop_worker_review_patch_transfers_command_id_artifact_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_review_patch_transfers_command_id_artifact_id_index ON public.coop_worker_review_patch_transfers USING btree (command_id, artifact_id);


--
-- Name: coop_worker_workspace_checkpoints_command_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_worker_workspace_checkpoints_command_ref_index ON public.coop_worker_workspace_checkpoints USING btree (command_id, checkpoint_ref);


--
-- Name: coop_worker_workspace_checkpoints_session_ref_placement_generat; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_worker_workspace_checkpoints_session_ref_placement_generat ON public.coop_worker_workspace_checkpoints USING btree (session_ref, placement_generation);


--
-- Name: coop_workers_certificate_sha256_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX coop_workers_certificate_sha256_index ON public.coop_workers USING btree (certificate_sha256);


--
-- Name: coop_workers_workspace_ref_state_last_seen_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coop_workers_workspace_ref_state_last_seen_at_index ON public.coop_workers USING btree (workspace_ref, state, last_seen_at);


--
-- Name: delivery_reactions_claimable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX delivery_reactions_claimable ON public.delivery_reactions USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);


--
-- Name: delivery_reactions_delivery_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX delivery_reactions_delivery_ref_index ON public.delivery_reactions USING btree (delivery_ref);


--
-- Name: delivery_reactions_input_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX delivery_reactions_input_id_index ON public.delivery_reactions USING btree (input_id);


--
-- Name: episode_emisar_approvals_claimable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_emisar_approvals_claimable ON public.episode_emisar_approvals USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);


--
-- Name: episode_emisar_approvals_episode_id_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_emisar_approvals_episode_id_status_index ON public.episode_emisar_approvals USING btree (episode_id, status);


--
-- Name: episode_emisar_approvals_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_emisar_approvals_record_id_index ON public.episode_emisar_approvals USING btree (record_id);


--
-- Name: episode_emisar_approvals_request_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_emisar_approvals_request_id_index ON public.episode_emisar_approvals USING btree (request_id);


--
-- Name: episode_publication_followups_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_publication_followups_due ON public.episode_publication_followups USING btree (next_poll_at, lease_expires_at, inserted_at, id);


--
-- Name: episode_publication_followups_publication_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publication_followups_publication_id_index ON public.episode_publication_followups USING btree (publication_id);


--
-- Name: episode_publication_lifecycle_delivery_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_publication_lifecycle_delivery_due ON public.episode_publication_lifecycle_events USING btree (delivery_state, next_attempt_at, lease_expires_at, inserted_at, id);


--
-- Name: episode_publication_lifecycle_events_delivery_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publication_lifecycle_events_delivery_ref_index ON public.episode_publication_lifecycle_events USING btree (delivery_ref);


--
-- Name: episode_publication_lifecycle_events_publication_id_occurred_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_publication_lifecycle_events_publication_id_occurred_at ON public.episode_publication_lifecycle_events USING btree (publication_id, occurred_at, id);


--
-- Name: episode_publication_lifecycle_events_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publication_lifecycle_events_ref_index ON public.episode_publication_lifecycle_events USING btree (ref);


--
-- Name: episode_publications_approval_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publications_approval_ref_index ON public.episode_publications USING btree (approval_ref) WHERE (approval_ref IS NOT NULL);


--
-- Name: episode_publications_claimable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_publications_claimable ON public.episode_publications USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);


--
-- Name: episode_publications_episode_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_publications_episode_id_inserted_at_index ON public.episode_publications USING btree (episode_id, inserted_at);


--
-- Name: episode_publications_id_episode_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publications_id_episode_id_index ON public.episode_publications USING btree (id, episode_id);


--
-- Name: episode_publications_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publications_record_id_index ON public.episode_publications USING btree (record_id);


--
-- Name: episode_publications_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publications_ref_index ON public.episode_publications USING btree (ref);


--
-- Name: episode_publications_review_request_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_publications_review_request_ref_index ON public.episode_publications USING btree (review_request_ref);


--
-- Name: episode_schedule_occurrences_child_episode_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_schedule_occurrences_child_episode_id_index ON public.episode_schedule_occurrences USING btree (child_episode_id) WHERE (child_episode_id IS NOT NULL);


--
-- Name: episode_schedule_occurrences_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_schedule_occurrences_ref_index ON public.episode_schedule_occurrences USING btree (ref);


--
-- Name: episode_schedule_occurrences_schedule_id_scheduled_for_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_schedule_occurrences_schedule_id_scheduled_for_id_index ON public.episode_schedule_occurrences USING btree (schedule_id, scheduled_for, id);


--
-- Name: episode_schedule_occurrences_schedule_id_scheduled_for_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_schedule_occurrences_schedule_id_scheduled_for_index ON public.episode_schedule_occurrences USING btree (schedule_id, scheduled_for);


--
-- Name: episode_schedules_destination_transport_destination_conversatio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_schedules_destination_transport_destination_conversatio ON public.episode_schedules USING btree (destination_transport, destination_conversation_ref);


--
-- Name: episode_schedules_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_schedules_due ON public.episode_schedules USING btree (status, next_occurrence_at, next_attempt_at, lease_expires_at, id);


--
-- Name: episode_schedules_offer_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_schedules_offer_record_id_index ON public.episode_schedules USING btree (offer_record_id);


--
-- Name: episode_schedules_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_schedules_ref_index ON public.episode_schedules USING btree (ref);


--
-- Name: episode_state_record_goal_subject_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_record_goal_subject_index ON public.episode_state_records USING btree (episode_id, subject_ref) WHERE (kind = 'goal'::text);


--
-- Name: episode_state_record_responses_inbox_entry_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_record_responses_inbox_entry_id_index ON public.episode_state_record_responses USING btree (inbox_entry_id);


--
-- Name: episode_state_record_responses_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_record_responses_record_id_index ON public.episode_state_record_responses USING btree (record_id);


--
-- Name: episode_state_record_responses_response_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_record_responses_response_ref_index ON public.episode_state_record_responses USING btree (response_ref);


--
-- Name: episode_state_record_subject_timeline_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_state_record_subject_timeline_index ON public.episode_state_records USING btree (episode_id, kind, subject_ref, inserted_at);


--
-- Name: episode_state_records_confirmed_episode_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_records_confirmed_episode_id_index ON public.episode_state_records USING btree (confirmed_episode_id) WHERE (confirmed_episode_id IS NOT NULL);


--
-- Name: episode_state_records_episode_id_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_state_records_episode_id_inserted_at_index ON public.episode_state_records USING btree (episode_id, inserted_at);


--
-- Name: episode_state_records_episode_id_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX episode_state_records_episode_id_sequence_index ON public.episode_state_records USING btree (episode_id, sequence);


--
-- Name: episode_state_records_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_records_ref_index ON public.episode_state_records USING btree (ref);


--
-- Name: episode_state_records_sequence_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_records_sequence_index ON public.episode_state_records USING btree (sequence);


--
-- Name: episode_state_records_turn_id_operation_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX episode_state_records_turn_id_operation_id_index ON public.episode_state_records USING btree (turn_id, operation_id);


--
-- Name: input_artifacts_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX input_artifacts_ref_index ON public.input_artifacts USING btree (ref);


--
-- Name: input_artifacts_source_kind_source_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX input_artifacts_source_kind_source_ref_index ON public.input_artifacts USING btree (source_kind, source_ref);


--
-- Name: operational_memory_active_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operational_memory_active_identity ON public.operational_memory_entries USING btree (workspace_ref, scope_kind, scope_ref, kind, subject) WHERE (status = 'active'::text);


--
-- Name: operational_memory_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operational_memory_context ON public.operational_memory_entries USING btree (workspace_ref, status, visibility, expires_at, updated_at);


--
-- Name: operational_memory_entries_offer_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operational_memory_entries_offer_record_id_index ON public.operational_memory_entries USING btree (offer_record_id);


--
-- Name: operational_memory_entries_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operational_memory_entries_ref_index ON public.operational_memory_entries USING btree (ref);


--
-- Name: operator_behaviors_active_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_behaviors_active_identity ON public.operator_behaviors USING btree (kind, workspace_ref, scope_kind, scope_ref, identity_key) WHERE (status = 'active'::text);


--
-- Name: operator_behaviors_context; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX operator_behaviors_context ON public.operator_behaviors USING btree (workspace_ref, kind, status, expires_at, updated_at);


--
-- Name: operator_behaviors_offer_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_behaviors_offer_record_id_index ON public.operator_behaviors USING btree (offer_record_id);


--
-- Name: operator_behaviors_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX operator_behaviors_ref_index ON public.operator_behaviors USING btree (ref);


--
-- Name: platform_actions_action_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX platform_actions_action_ref_index ON public.platform_actions USING btree (action_ref);


--
-- Name: platform_actions_claimable; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX platform_actions_claimable ON public.platform_actions USING btree (status, next_attempt_at, lease_expires_at, inserted_at, id);


--
-- Name: platform_actions_turn_id_host_slot_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX platform_actions_turn_id_host_slot_index ON public.platform_actions USING btree (turn_id, host_slot);


--
-- Name: retention_operator_actions_action_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX retention_operator_actions_action_ref_index ON public.retention_operator_actions USING btree (action_ref);


--
-- Name: retention_operator_actions_session_id_occurred_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX retention_operator_actions_session_id_occurred_at_id_index ON public.retention_operator_actions USING btree (session_id, occurred_at, id);


--
-- Name: slack_channel_configurations_workspace_ref_channel_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_channel_configurations_workspace_ref_channel_ref_index ON public.slack_channel_configurations USING btree (workspace_ref, channel_ref);


--
-- Name: slack_channel_membership_events_workspace_ref_event_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_channel_membership_events_workspace_ref_event_ref_index ON public.slack_channel_membership_events USING btree (workspace_ref, event_ref);


--
-- Name: slack_channel_memberships_workspace_ref_channel_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_channel_memberships_workspace_ref_channel_ref_index ON public.slack_channel_memberships USING btree (workspace_ref, channel_ref);


--
-- Name: slack_channel_setting_audit_event_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_channel_setting_audit_event_ref_index ON public.slack_channel_setting_audit USING btree (event_ref);


--
-- Name: slack_channel_setting_audit_workspace_ref_occurred_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_channel_setting_audit_workspace_ref_occurred_at_id_index ON public.slack_channel_setting_audit USING btree (workspace_ref, occurred_at, id);


--
-- Name: slack_channel_setting_identity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_channel_setting_identity ON public.slack_channel_setting_overrides USING btree (workspace_ref, scope_kind, scope_ref, setting);


--
-- Name: slack_channel_setting_overrides_workspace_ref_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_channel_setting_overrides_workspace_ref_updated_at_index ON public.slack_channel_setting_overrides USING btree (workspace_ref, updated_at);


--
-- Name: slack_configuration_actions_event_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_configuration_actions_event_ref_index ON public.slack_configuration_actions USING btree (event_ref);


--
-- Name: slack_configuration_sessions_active_channel_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_configuration_sessions_active_channel_index ON public.slack_configuration_sessions USING btree (workspace_ref, channel_ref) WHERE (status = ANY (ARRAY['asking'::text, 'confirming'::text]));


--
-- Name: slack_configuration_sessions_start_event_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_configuration_sessions_start_event_ref_index ON public.slack_configuration_sessions USING btree (start_event_ref);


--
-- Name: slack_configuration_sessions_status_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_configuration_sessions_status_expires_at_index ON public.slack_configuration_sessions USING btree (status, expires_at);


--
-- Name: slack_incident_room_lifecycle_events_room_id_occurred_at_event_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_incident_room_lifecycle_events_room_id_occurred_at_event_ ON public.slack_incident_room_lifecycle_events USING btree (room_id, occurred_at, event_ref);


--
-- Name: slack_incident_room_lifecycle_events_workspace_ref_event_ref_in; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_room_lifecycle_events_workspace_ref_event_ref_in ON public.slack_incident_room_lifecycle_events USING btree (workspace_ref, event_ref);


--
-- Name: slack_incident_rooms_episode_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_rooms_episode_id_index ON public.slack_incident_rooms USING btree (episode_id) WHERE (episode_id IS NOT NULL);


--
-- Name: slack_incident_rooms_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_rooms_record_id_index ON public.slack_incident_rooms USING btree (record_id);


--
-- Name: slack_incident_rooms_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_rooms_ref_index ON public.slack_incident_rooms USING btree (ref);


--
-- Name: slack_incident_rooms_status_next_attempt_at_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_incident_rooms_status_next_attempt_at_inserted_at_index ON public.slack_incident_rooms USING btree (status, next_attempt_at, inserted_at) WHERE (status = 'requested'::text);


--
-- Name: slack_incident_rooms_status_next_attempt_at_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_incident_rooms_status_next_attempt_at_updated_at_index ON public.slack_incident_rooms USING btree (status, next_attempt_at, updated_at) WHERE ((status = 'ready'::text) AND (channel_state <> reconciled_channel_state));


--
-- Name: slack_incident_rooms_status_root_card_checked_at_updated_at_ind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_incident_rooms_status_root_card_checked_at_updated_at_ind ON public.slack_incident_rooms USING btree (status, root_card_checked_at, updated_at) WHERE ((status = 'ready'::text) AND (channel_state = 'active'::text));


--
-- Name: slack_incident_rooms_workspace_ref_channel_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_rooms_workspace_ref_channel_name_index ON public.slack_incident_rooms USING btree (workspace_ref, channel_name);


--
-- Name: slack_incident_rooms_workspace_ref_channel_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_incident_rooms_workspace_ref_channel_ref_index ON public.slack_incident_rooms USING btree (workspace_ref, channel_ref) WHERE (channel_ref IS NOT NULL);


--
-- Name: slack_interaction_audit_event_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_interaction_audit_event_ref_index ON public.slack_interaction_audit USING btree (event_ref);


--
-- Name: slack_interaction_audit_workspace_ref_occurred_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_interaction_audit_workspace_ref_occurred_at_id_index ON public.slack_interaction_audit USING btree (workspace_ref, occurred_at, id);


--
-- Name: slack_interaction_repaint_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_interaction_repaint_due ON public.slack_interaction_audit USING btree (repaint_status, next_attempt_at, occurred_at, id);


--
-- Name: slack_source_audits_episode_id_inserted_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_source_audits_episode_id_inserted_at_id_index ON public.slack_source_audits USING btree (episode_id, inserted_at, id);


--
-- Name: slack_source_audits_turn_id_inserted_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_source_audits_turn_id_inserted_at_id_index ON public.slack_source_audits USING btree (turn_id, inserted_at, id);


--
-- Name: slack_task_cards_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX slack_task_cards_due ON public.slack_task_cards USING btree (card_checked_at, updated_at);


--
-- Name: slack_task_cards_episode_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_task_cards_episode_id_index ON public.slack_task_cards USING btree (episode_id);


--
-- Name: slack_task_cards_record_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_task_cards_record_id_index ON public.slack_task_cards USING btree (record_id);


--
-- Name: slack_task_cards_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX slack_task_cards_ref_index ON public.slack_task_cards USING btree (ref);


--
-- Name: standing_assignment_runs_assignment_id_source_input_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX standing_assignment_runs_assignment_id_source_input_ref_index ON public.standing_assignment_runs USING btree (assignment_id, source_input_ref);


--
-- Name: standing_assignment_runs_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX standing_assignment_runs_ref_index ON public.standing_assignment_runs USING btree (ref);


--
-- Name: work_output_artifacts_turn_id_ref_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX work_output_artifacts_turn_id_ref_index ON public.work_output_artifacts USING btree (turn_id, ref);


--
-- Name: work_output_artifacts_turn_id_sha256_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX work_output_artifacts_turn_id_sha256_index ON public.work_output_artifacts USING btree (turn_id, sha256);


--
-- Name: coop_session_placements coop_session_placement_session_episode_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placement_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;


--
-- Name: coop_session_placements coop_session_placements_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE RESTRICT;


--
-- Name: coop_session_placements coop_session_placements_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: coop_session_placements coop_session_placements_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_session_placements
    ADD CONSTRAINT coop_session_placements_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.coop_workers(id) ON DELETE RESTRICT;


--
-- Name: coop_worker_certificates coop_worker_certificates_enrollment_token_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_enrollment_token_id_fkey FOREIGN KEY (enrollment_token_id) REFERENCES public.coop_worker_enrollment_tokens(id) ON DELETE SET NULL;


--
-- Name: coop_worker_certificates coop_worker_certificates_worker_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_certificates
    ADD CONSTRAINT coop_worker_certificates_worker_id_fkey FOREIGN KEY (worker_id) REFERENCES public.coop_workers(id) ON DELETE RESTRICT;


--
-- Name: coop_worker_commands coop_worker_command_placement_identity_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_commands
    ADD CONSTRAINT coop_worker_command_placement_identity_fkey FOREIGN KEY (placement_id, worker_id, session_id, placement_generation) REFERENCES public.coop_session_placements(id, worker_id, session_id, generation) ON DELETE RESTRICT;


--
-- Name: coop_worker_events coop_worker_event_placement_identity_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_events
    ADD CONSTRAINT coop_worker_event_placement_identity_fkey FOREIGN KEY (placement_id, worker_id, session_id, placement_generation) REFERENCES public.coop_session_placements(id, worker_id, session_id, generation) ON DELETE RESTRICT;


--
-- Name: coop_worker_output_transfers coop_worker_output_transfer_command_worker_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_output_transfers
    ADD CONSTRAINT coop_worker_output_transfer_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;


--
-- Name: coop_worker_review_patch_transfers coop_worker_review_patch_command_worker_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_review_patch_transfers
    ADD CONSTRAINT coop_worker_review_patch_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;


--
-- Name: coop_worker_workspace_checkpoints coop_worker_workspace_checkpoint_command_worker_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coop_worker_workspace_checkpoints
    ADD CONSTRAINT coop_worker_workspace_checkpoint_command_worker_fkey FOREIGN KEY (command_id, worker_id) REFERENCES public.coop_worker_commands(id, worker_id) ON DELETE CASCADE;


--
-- Name: delivery_reactions delivery_reactions_input_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_reactions
    ADD CONSTRAINT delivery_reactions_input_id_fkey FOREIGN KEY (input_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE RESTRICT;


--
-- Name: episode_emisar_approvals episode_emisar_approvals_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_emisar_approvals episode_emisar_approvals_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_emisar_approvals
    ADD CONSTRAINT episode_emisar_approvals_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: episode_publication_followups episode_publication_followup_publication_episode_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followup_publication_episode_fkey FOREIGN KEY (publication_id, episode_id) REFERENCES public.episode_publications(id, episode_id) ON DELETE CASCADE;


--
-- Name: episode_publication_followups episode_publication_followups_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_followups
    ADD CONSTRAINT episode_publication_followups_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_publication_lifecycle_events episode_publication_lifecycle_events_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_events_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_publication_lifecycle_events episode_publication_lifecycle_publication_episode_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publication_lifecycle_events
    ADD CONSTRAINT episode_publication_lifecycle_publication_episode_fkey FOREIGN KEY (publication_id, episode_id) REFERENCES public.episode_publications(id, episode_id) ON DELETE CASCADE;


--
-- Name: episode_publications episode_publication_session_episode_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publication_session_episode_fkey FOREIGN KEY (session_id, episode_id) REFERENCES public.episode_work_sessions(id, episode_id) ON DELETE RESTRICT;


--
-- Name: episode_publications episode_publications_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_publications episode_publications_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_publications
    ADD CONSTRAINT episode_publications_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: episode_schedule_occurrences episode_schedule_occurrences_child_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_child_episode_id_fkey FOREIGN KEY (child_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_schedule_occurrences episode_schedule_occurrences_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedule_occurrences
    ADD CONSTRAINT episode_schedule_occurrences_schedule_id_fkey FOREIGN KEY (schedule_id) REFERENCES public.episode_schedules(id) ON DELETE CASCADE;


--
-- Name: episode_schedules episode_schedules_offer_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: episode_schedules episode_schedules_source_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_schedules
    ADD CONSTRAINT episode_schedules_source_episode_id_fkey FOREIGN KEY (source_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_state_record_responses episode_state_record_responses_inbox_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_inbox_entry_id_fkey FOREIGN KEY (inbox_entry_id) REFERENCES public.ingress_inbox_entries(id) ON DELETE RESTRICT;


--
-- Name: episode_state_record_responses episode_state_record_responses_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_record_responses
    ADD CONSTRAINT episode_state_record_responses_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: episode_state_records episode_state_record_turn_episode_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_record_turn_episode_fkey FOREIGN KEY (turn_id, episode_id) REFERENCES public.episode_work_turns(id, episode_id) ON DELETE RESTRICT;


--
-- Name: episode_state_records episode_state_records_confirmed_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_confirmed_episode_id_fkey FOREIGN KEY (confirmed_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: episode_state_records episode_state_records_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.episode_state_records
    ADD CONSTRAINT episode_state_records_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: operational_memory_entries operational_memory_entries_offer_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operational_memory_entries
    ADD CONSTRAINT operational_memory_entries_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: operator_behaviors operator_behaviors_offer_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operator_behaviors
    ADD CONSTRAINT operator_behaviors_offer_record_id_fkey FOREIGN KEY (offer_record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: platform_actions platform_actions_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: platform_actions platform_actions_turn_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.platform_actions
    ADD CONSTRAINT platform_actions_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE RESTRICT;


--
-- Name: retention_operator_actions retention_operator_actions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.retention_operator_actions
    ADD CONSTRAINT retention_operator_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.episode_work_sessions(id) ON DELETE RESTRICT;


--
-- Name: slack_channel_membership_events slack_channel_membership_events_membership_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_channel_membership_events
    ADD CONSTRAINT slack_channel_membership_events_membership_id_fkey FOREIGN KEY (membership_id) REFERENCES public.slack_channel_memberships(id) ON DELETE CASCADE;


--
-- Name: slack_configuration_actions slack_configuration_actions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_configuration_actions
    ADD CONSTRAINT slack_configuration_actions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.slack_configuration_sessions(id) ON DELETE CASCADE;


--
-- Name: slack_incident_room_lifecycle_events slack_incident_room_lifecycle_events_room_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_room_lifecycle_events
    ADD CONSTRAINT slack_incident_room_lifecycle_events_room_id_fkey FOREIGN KEY (room_id) REFERENCES public.slack_incident_rooms(id) ON DELETE RESTRICT;


--
-- Name: slack_incident_rooms slack_incident_rooms_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: slack_incident_rooms slack_incident_rooms_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: slack_incident_rooms slack_incident_rooms_source_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_incident_rooms
    ADD CONSTRAINT slack_incident_rooms_source_episode_id_fkey FOREIGN KEY (source_episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: slack_source_audits slack_source_audits_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE CASCADE;


--
-- Name: slack_source_audits slack_source_audits_turn_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_source_audits
    ADD CONSTRAINT slack_source_audits_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;


--
-- Name: slack_task_cards slack_task_cards_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: slack_task_cards slack_task_cards_record_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.slack_task_cards
    ADD CONSTRAINT slack_task_cards_record_id_fkey FOREIGN KEY (record_id) REFERENCES public.episode_state_records(id) ON DELETE RESTRICT;


--
-- Name: standing_assignment_runs standing_assignment_runs_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_assignment_id_fkey FOREIGN KEY (assignment_id) REFERENCES public.operator_behaviors(id) ON DELETE CASCADE;


--
-- Name: standing_assignment_runs standing_assignment_runs_episode_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.standing_assignment_runs
    ADD CONSTRAINT standing_assignment_runs_episode_id_fkey FOREIGN KEY (episode_id) REFERENCES public.episode_kernel_episodes(id) ON DELETE RESTRICT;


--
-- Name: work_output_artifacts work_output_artifacts_turn_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.work_output_artifacts
    ADD CONSTRAINT work_output_artifacts_turn_id_fkey FOREIGN KEY (turn_id) REFERENCES public.episode_work_turns(id) ON DELETE CASCADE;


--
