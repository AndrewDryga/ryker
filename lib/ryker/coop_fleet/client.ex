defmodule Ryker.CoopFleet.Client do
  @moduledoc """
  Coop API adapter backed by the durable outbound worker command plane.

  It preserves the existing Work executor contract while replacing direct
  Unix-socket calls with placed, leased, idempotent worker commands.
  """
  @behaviour Ryker.Coop.API
  alias Ryker.{Artifacts, CanonicalJSON}
  alias Ryker.CoopFleet.{Bodies, Bridge, Checkpoints, Command, ControlPlane}
  alias Ryker.CoopFleet.ControlPlane.Commands
  alias Ryker.CoopFleet.{JobAuthority, Placement, Worker}
  alias Ryker.CoopFleet.WorkspaceCheckpointTransfer
  alias Ryker.Crypto
  alias Ryker.Repo
  alias Ryker.Work.{RepositorySource, Session}

  @fields [:bridge, :bridge_options, :source_root]
  @option_keys [
    :body_root,
    :checkpoint_key,
    :bridge,
    :capability_names,
    :capability_versions,
    :lease_seconds,
    :max_waits,
    :poll_interval_ms,
    :source_root,
    :wait,
    :workspace_ref
  ]
  @enforce_keys [:bridge, :bridge_options]
  # Crash reports print a struct with inspect; the bridge options carry the
  # checkpoint key and the value of every saved credential.
  @derive {Inspect, except: [:bridge_options]}
  defstruct @fields

  @type t :: %__MODULE__{bridge: module(), bridge_options: keyword()}

  @repository_freshness_capability "repository-freshness"

  @doc """
  The capability versions a worker must advertise to be given a session:
  version-2 source freshness receipts, and Coop's `job-setup:2`, because every
  job Ryker freezes is a version-2 JobSpec that an older worker refuses
  (Coop 33ea84fe).
  """
  @spec capability_versions() :: %{String.t() => String.t()}
  def capability_versions, do: %{"job-setup" => "2", "repository-freshness" => "2"}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(options) do
    with {:ok, options} <- normalize_options(options),
         true <- valid_workspace_ref?(options[:workspace_ref]),
         true <- is_atom(Map.get(options, :bridge, Bridge)) do
      bridge = Map.get(options, :bridge, Bridge)

      {:ok,
       %__MODULE__{
         bridge: bridge,
         source_root: Map.get(options, :source_root),
         bridge_options:
           options
           |> Map.drop([:bridge, :source_root])
           |> Map.put_new(:capability_names, ["controller-tools"])
           |> Map.put_new(:capability_versions, %{})
           |> Enum.to_list()
       }}
    else
      false -> {:error, {:invalid_coop_fleet_client, :options}}
      {:error, {:invalid_coop_fleet_client, :options}} = error -> error
    end
  end

  @impl true
  def prepare_create_session(client, key, policy, task, source) do
    with {:ok, session} <- create_session_identity(key, task),
         :ok <- exact_authority(session, policy, source),
         {:ok, _session} <- JobAuthority.ensure_pinned(session, client.source_root),
         do: :ok
  end

  @impl true
  def create_session(client, key, policy, task, source) do
    with {:ok, session} <- create_session_identity(key, task),
         :ok <- exact_authority(session, policy, source),
         {:ok, payload} <- create_session_payload(session, policy, task, source),
         {:ok, remote} <- execute(client, session, "create_session", payload, key) do
      ensure_workspace(client, session, remote, key)
    end
  end

  # The fleet forwards only the authority Work custody persisted: a worker never
  # receives a policy or repository source other than the one pinned on the
  # session it is being asked to create.
  defp exact_authority(%Session{} = session, policy, source) do
    with {:ok, source} <- repository_source(source) do
      cond do
        session.policy != policy ->
          {:error, {:coop_fleet_authority_mismatch, :policy}}

        not RepositorySource.same?(session.repository_source, source) ->
          {:error, {:coop_fleet_authority_mismatch, :repository_source}}

        true ->
          :ok
      end
    end
  end

  defp repository_source(source) do
    case RepositorySource.parse_optional(source) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, {:invalid_coop_request, :repository_source}}
    end
  end

  defp ensure_workspace(_client, %Session{workspace_task: nil}, remote, _create_key),
    do: {:ok, remote}

  defp ensure_workspace(
         client,
         %Session{workspace_task: task} = session,
         %{"session" => remote},
         create_key
       )
       when is_map(task) do
    with coop_session_id when is_binary(coop_session_id) <- remote["id"],
         revision when is_integer(revision) and revision > 0 <- remote["revision"],
         {:ok, checkpoint} <- restore_checkpoint(session) do
      key =
        "ryker:workspace:" <>
          CanonicalJSON.digest(%{
            "create_key" => create_key,
            "checkpoint" => checkpoint,
            "session_id" => session.id,
            "task" => task
          })

      payload =
        %{
          "coop_session_id" => coop_session_id,
          "expected_revision" => revision,
          "task" => task
        }
        |> maybe_put_checkpoint(checkpoint)

      execute(
        client,
        session,
        "ensure_workspace",
        payload,
        key
      )
    else
      {:error, _} = error -> error
      _invalid -> {:error, {:coop_protocol_error, :create_session_response}}
    end
  end

  defp ensure_workspace(_client, _session, %{"operation" => operation} = response, _key)
       when is_map(operation), do: {:ok, response}

  defp ensure_workspace(_client, _session, _response, _key),
    do: {:error, {:coop_protocol_error, :create_session_response}}

  @impl true
  def checkpoint_workspace(client, coop_session_id, key, expected_revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         repository_ref when is_binary(repository_ref) <- session.repository_ref,
         {:ok, response} <-
           execute(
             client,
             session,
             "checkpoint_workspace",
             %{
               "coop_session_id" => coop_session_id,
               "expected_revision" => expected_revision,
               "repository_ref" => repository_ref,
               "session_ref" => session.id
             },
             key
           ) do
      Checkpoints.capture(session.id, key, response, client.bridge_options)
    else
      {:error, _} = error -> error
      _invalid -> {:error, {:coop_workspace_checkpoint_unavailable, coop_session_id}}
    end
  end

  @impl true
  def accepts_session?(client, %Session{} = session),
    do: client.bridge.accepts?(session, client.bridge_options)

  @impl true
  def fence_create_session(client, key, policy, task, source) do
    with {:ok, session} <- create_session_identity(key, task),
         :ok <- exact_authority(session, policy, source) do
      fence_create_authority(client, session, key, policy, task, source)
    end
  end

  defp fence_create_authority(
         client,
         session,
         key,
         policy,
         task,
         source
       ) do
    with {:ok, payload} <- fence_create_payload(session, policy, task, source),
         {:ok, command} <-
           ControlPlane.fence_command(
             session,
             "create_session",
             Commands.create_intent(session, task),
             key
           ) do
      fenced_command(client, command, key, payload)
    end
  end

  defp fence_create_payload(%Session{worker_job_document: nil, worker_job_digest: nil}, _, _, _),
    do: {:ok, nil}

  defp fence_create_payload(session, policy, task, source),
    do: create_session_payload(session, policy, task, source)

  @impl true
  def get_session(client, coop_session_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      case durable_prebinding_session(session, coop_session_id) do
        {:ok, remote_session} ->
          {:ok, remote_session}

        :not_found ->
          execute_read(client, session, "get_session", %{"coop_session_id" => coop_session_id})
      end
    end
  end

  @impl true
  def prepare_session(client, coop_session_id, key) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      case Repo.one(Command.Query.by_idempotency_key(key)) do
        nil ->
          prepare_on_idle_worker(client, session, coop_session_id, key)

        %Command{kind: "prepare_session", session_id: id, payload: payload}
        when id == session.id ->
          execute(client, session, "prepare_session", payload, key)

        _other ->
          {:error, {:coop_worker_command_conflict, key}}
      end
    end
  end

  # Coop starts the agent before it answers a prepare, after waiting for a
  # free runtime slot, and the worker runs one command at a time: sent to a
  # worker with anything else to do, a prepare would hold all of it until the
  # agent runs. Nothing is sent to a busy worker; the caller asks again.
  defp prepare_on_idle_worker(client, session, coop_session_id, key) do
    if ControlPlane.worker_idle?(session.id) do
      with {:ok, remote} <-
             execute_read(client, session, "get_session", %{"coop_session_id" => coop_session_id}),
           {:ok, revision} <- open_revision(remote) do
        execute(
          client,
          session,
          "prepare_session",
          %{"coop_session_id" => coop_session_id, "expected_revision" => revision},
          key
        )
      end
    else
      {:error, :coop_worker_busy}
    end
  end

  defp open_revision(%{"state" => "open", "revision" => revision})
       when is_integer(revision) and revision > 0,
       do: {:ok, revision}

  defp open_revision(%{"state" => state}) when is_binary(state) and state != "open",
    do: {:error, {:coop_session_not_open, state}}

  defp open_revision(_remote), do: {:error, {:coop_protocol_error, :session_revision}}

  @impl true
  def get_session_evidence(client, coop_session_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_session_evidence", %{
        "coop_session_id" => coop_session_id
      })
    end
  end

  @impl true
  def capabilities(%__MODULE__{} = client, %Session{id: session_id} = session) do
    now = Repo.now!()

    current =
      session_id
      |> Placement.Query.by_session_id()
      |> Placement.Query.current()
      |> Placement.Query.with_joined_worker()
      |> Placement.Query.select_with_workers()
      |> Placement.Query.limit_to(1)

    case Repo.one(current) do
      {%Placement{state: :active, lease_expires_at: expires_at}, %Worker{} = worker}
      when not is_nil(expires_at) ->
        placed_freshness_capabilities(worker, expires_at, now)

      nil when is_nil(session.coop_session_id) ->
        configured_freshness_capabilities(client)

      _unavailable ->
        {:error, {:coop_upgrade_required, :repository_freshness_v2}}
    end
  end

  defp placed_freshness_capabilities(worker, expires_at, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: {:ok, advertised_capability_document(worker.capabilities)},
      else: {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  # Before placement the configured fleet requirement is the only evidence; a
  # worker that has not advertised the capability is never eligible anyway.
  defp configured_freshness_capabilities(client) do
    versions = Keyword.get(client.bridge_options, :capability_versions, %{})

    {:ok,
     %{
       "repository_freshness_receipt_versions" =>
         capability_versions(versions[@repository_freshness_capability] == "2", 2)
     }}
  end

  defp advertised_capability_document(capabilities) do
    %{
      "repository_freshness_receipt_versions" =>
        capability_versions(advertised?(capabilities, @repository_freshness_capability, "2"), 2)
    }
  end

  defp advertised?(capabilities, name, version),
    do: Enum.any?(capabilities, &(&1["name"] == name and &1["version"] == version))

  defp capability_versions(true, version), do: [version]
  defp capability_versions(false, _version), do: []

  @impl true
  def get_changes(client, coop_session_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_changes", %{"coop_session_id" => coop_session_id})
    end
  end

  @impl true
  def get_changes_page(client, coop_session_id, patch_offset, patch_limit) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_changes_page", %{
        "coop_session_id" => coop_session_id,
        "patch_limit" => patch_limit,
        "patch_offset" => patch_offset
      })
    end
  end

  @impl true
  def read_review_gate_output(client, coop_session_id, review_operation_id, cursor) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_review_gate_output", %{
        "coop_session_id" => coop_session_id,
        "cursor" => cursor,
        "operation_id" => review_operation_id
      })
    end
  end

  @impl true
  def run_review(client, coop_session_id, key, expected_revision) do
    with {:ok, %Session{id: session_id} = session} <- session_by_coop_id(coop_session_id) do
      payload = %{"coop_session_id" => coop_session_id, "expected_revision" => expected_revision}

      case Repo.one(Command.Query.by_idempotency_key(key)) do
        %Command{
          status: :uncertain,
          session_id: ^session_id,
          kind: "run_review",
          payload: ^payload
        } =
            command ->
          reconcile_review(client, session, command, coop_session_id, expected_revision)

        %Command{status: :uncertain} ->
          {:error, {:coop_worker_command_conflict, key}}

        _not_uncertain ->
          execute(client, session, "run_review", payload, key)
      end
    end
  end

  defp reconcile_review(client, session, command, coop_session_id, revision) do
    # A review may finish after its HTTP request times out. Keep that receipt and read the
    # original operation where it runs: in the session service of the worker holding the
    # session, which keeps operations by key, through whichever placement addresses it now.
    # The placement that ran the review may have lapsed since (OrbStack crashed mid-review
    # on 30 Sep); another worker never holds it.
    with {:ok, placement} <- review_holder_placement(client, session, command),
         {:ok, reconciliation} <-
           ControlPlane.enqueue_command(
             placement.id,
             "reconcile_operation",
             %{"operation_key" => command.idempotency_key},
             Command.read_key("reconcile_operation")
           ),
         {:ok, response} <-
           client.bridge.await_command(reconciliation.id, client.bridge_options) do
      reconciled_review(client, placement, command, response, coop_session_id, revision)
    end
  end

  defp reconciled_review(
         client,
         placement,
         command,
         %{
           "id" => operation_id,
           "method" => "RunReview",
           "state" => "succeeded",
           "resource_type" => "review",
           "resource_id" => coop_session_id
         },
         coop_session_id,
         revision
       ) do
    with {:ok, lookup} <-
           ControlPlane.enqueue_command(
             placement.id,
             "get_review",
             %{"coop_session_id" => coop_session_id, "operation_id" => operation_id},
             "ryker:fleet:review:#{command.id}:#{operation_id}"
           ),
         {:ok, %{"operation" => %{"id" => ^operation_id}} = review} <-
           client.bridge.await_command(lookup.id, client.bridge_options) do
      review_resource(review, coop_session_id, revision)
    else
      {:ok, _other} -> {:error, {:coop_protocol_error, :review_resource}}
      error -> error
    end
  end

  defp reconciled_review(_client, _placement, _command, response, coop_session_id, revision),
    do: review_resource(response, coop_session_id, revision)

  defp review_resource(
         %{
           "operation" => %{
             "id" => operation_id,
             "method" => "RunReview",
             "state" => "succeeded",
             "resource_type" => "review",
             "resource_id" => session_id
           },
           "review" => %{
             "operation_id" => operation_id,
             "session_id" => session_id,
             "session_revision" => revision
           }
         } = response,
         session_id,
         revision
       )
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, response}

  defp review_resource(%{"method" => "RunReview", "state" => state}, _session_id, _revision)
       when state in ["reserved", "running"],
       do: {:error, {:coop_unavailable, "Review operation has not completed."}}

  # Coop marks an operation uncertain when its service restarts under it, and that review
  # never finishes: waiting on it kept a publication pending forever. Its caller starts the
  # review again under a new key.
  defp review_resource(
         %{"method" => "RunReview", "state" => "uncertain"},
         _session_id,
         _revision
       ),
       do: {:error, {:coop_review_lost, "The review stopped when its worker restarted."}}

  defp review_resource(
         %{
           "method" => "RunReview",
           "state" => "failed",
           "error_code" => code,
           "error_detail" => detail
         },
         _session_id,
         _revision
       )
       when is_binary(code) and code != "" and is_binary(detail) do
    # The saved operation carries no HTTP status; 0 is the bridge's own convention
    # for that, and a revision conflict keeps its 409 so publication re-stages.
    status = if code == "revision_conflict", do: 409, else: 0
    {:error, {:coop_error, status, code, detail}}
  end

  defp review_resource(_response, _session_id, _revision),
    do: {:error, {:coop_protocol_error, :review_resource}}

  @impl true
  def publish_review(client, coop_session_id, review_key, review_id, key, body) do
    with {:ok, %Session{id: session_id} = session} <- session_by_coop_id(coop_session_id),
         %Command{
           session_id: ^session_id,
           kind: "run_review",
           payload: %{"coop_session_id" => ^coop_session_id},
           placement_id: placement_id
         } = owner
         when not is_nil(placement_id) <- Repo.one(Command.Query.by_idempotency_key(review_key)),
         path <- "/v1/sessions/#{coop_session_id}/reviews/#{review_id}/publish",
         {:ok, command} <- publication_command(client, session, owner, key, path, body),
         {:ok, response} <- publication_command_response(client, command) do
      publication_result(client, command, coop_session_id, response)
    else
      {:error, _reason} = error -> error
      _unproven -> {:error, {:coop_protocol_error, :publication_owner}}
    end
  end

  defp publication_command(client, session, owner, key, path, body) do
    case Repo.one(Command.Query.by_idempotency_key(key)) do
      %Command{
        kind: "api_request",
        payload: %{"method" => "POST", "path" => ^path, "body" => saved}
      } = command ->
        # Destination and prose freeze in the first durable command. A settings
        # refresh cannot reroute its retry, but approval/candidate drift is refused.
        identity =
          ~w(authorization_ref candidate_head candidate_tree expected_head pull_request_number)

        if command.worker_id == owner.worker_id and command.session_id == owner.session_id and
             Map.take(saved, identity) == Map.take(body, identity),
           do: {:ok, command},
           else: {:error, {:coop_worker_command_conflict, key}}

      nil ->
        with {:ok, placement} <- review_holder_placement(client, session, owner) do
          ControlPlane.enqueue_command(
            placement.id,
            "api_request",
            %{"method" => "POST", "path" => path, "body" => body},
            key
          )
        end

      _other ->
        {:error, {:coop_worker_command_conflict, key}}
    end
  end

  # The review lives in the worker's session, not in the placement that ran it, and a person
  # may approve the draft long after that placement's lease ran out. Placing the bound session
  # again returns it to the worker holding it, or fails closed when that worker cannot take it.
  # A placement on any other worker would have no review to publish.
  defp review_holder_placement(client, session, %Command{worker_id: worker_id} = owner) do
    case Bridge.place(session, client.bridge_options) do
      {:ok, %Placement{worker_id: ^worker_id} = placement} ->
        {:ok, placement}

      {:ok, %Placement{}} ->
        {:error,
         {:coop_session_replacement_required, owner.session_id, owner.placement_generation}}

      {:error, _reason} = error ->
        error
    end
  end

  defp publication_command_response(client, command) do
    # A completed result lookup is durable even if the original POST only
    # acknowledged a background operation and its placement has since expired.
    # The lookup runs on the worker holding the session, maybe on a newer placement.
    case Repo.one(Command.Query.by_idempotency_key(publication_result_key(command))) do
      %Command{status: :succeeded, session_id: session_id, worker_id: worker_id} = result
      when session_id == command.session_id and worker_id == command.worker_id ->
        Bridge.command_response(
          result,
          client.bridge_options[:body_root],
          client.bridge_options[:checkpoint_key]
        )

      _pending ->
        publication_post_response(client, command)
    end
  end

  defp publication_post_response(client, %Command{status: :succeeded} = command) do
    Bridge.command_response(
      command,
      client.bridge_options[:body_root],
      client.bridge_options[:checkpoint_key]
    )
  end

  defp publication_post_response(_client, %Command{status: :uncertain}), do: {:ok, :reconcile}

  defp publication_post_response(client, command),
    do: client.bridge.await_command(command.id, client.bridge_options)

  defp publication_result(_client, _command, session_id, %{
         "operation" => %{
           "method" => "PublishReview",
           "state" => "succeeded",
           "resource_type" => "publication",
           "resource_id" => session_id
         },
         "publication" => %{"status" => "published", "receipt" => receipt}
       }),
       do: {:ok, receipt}

  defp publication_result(_client, _command, session_id, %{
         "operation" => %{
           "method" => "PublishReview",
           "state" => "succeeded",
           "resource_type" => "publication",
           "resource_id" => session_id
         },
         "publication" => %{"status" => "conflict", "error_code" => code, "conflict" => receipt}
       })
       when is_map(receipt) and
              code in ~w(publication_branch_changed publication_branch_already_exists) do
    code =
      if code == "publication_branch_changed",
        do: :publication_branch_changed,
        else: :publication_branch_already_exists

    if is_integer(receipt["pull_request_number"]) and receipt["pull_request_number"] > 0 and
         receipt["observed_head_sha"] != "",
       do: {:error, {:publication_conflict, code, receipt}},
       else: {:error, code}
  end

  defp publication_result(_client, _command, session_id, %{
         "operation" => %{
           "method" => "PublishReview",
           "state" => "succeeded",
           "resource_type" => "publication",
           "resource_id" => session_id
         },
         "publication" => %{"status" => "refused", "error_code" => code}
       }) do
    case code do
      "publication_branch_changed" ->
        {:error, :publication_branch_changed}

      "publication_branch_already_exists" ->
        {:error, :publication_branch_already_exists}

      "publication_existing_pull_request_changed" ->
        {:error, :publication_existing_pull_request_changed}

      "publication_pull_request_mismatch" ->
        {:error, :publication_pull_request_mismatch}

      "publication_authorization_revoked" ->
        {:error, :publication_authorization_revoked}

      _unknown ->
        {:error, {:coop_protocol_error, :publication_refusal}}
    end
  end

  defp publication_result(_client, _command, _session_id, %{
         "operation" => %{"state" => "succeeded"}
       }),
       do: {:error, {:coop_protocol_error, :publication_resource}}

  # An accepted publish runs on the worker holding the session, whose session service keeps
  # the operation by key. The placement that asked for it may lapse before it finishes, as
  # when OrbStack crashed on 30 Sep; a newer placement on the same worker reads it.
  defp publication_result(client, command, session_id, response)
       when response == :reconcile or is_map_key(response, "operation") do
    with %Session{} = session <- Repo.one(Session.Query.by_id(command.session_id)),
         {:ok, placement} <- review_holder_placement(client, session, command),
         {:ok, lookup} <-
           ControlPlane.enqueue_command(
             placement.id,
             "reconcile_operation",
             %{"operation_key" => command.idempotency_key},
             Command.read_key("publication")
           ),
         {:ok, operation} <- client.bridge.await_command(lookup.id, client.bridge_options) do
      publication_operation(client, placement, command, session_id, operation)
    else
      nil -> {:error, {:coop_session_not_found, command.session_id}}
      {:error, _reason} = error -> error
    end
  end

  defp publication_result(_client, _command, _session_id, _response),
    do: {:error, {:coop_protocol_error, :publication_resource}}

  defp publication_operation(client, placement, command, session_id, %{
         "id" => operation_id,
         "method" => "PublishReview",
         "state" => "succeeded",
         "resource_type" => "publication",
         "resource_id" => session_id
       }) do
    with {:ok, lookup} <-
           ControlPlane.enqueue_command(
             placement.id,
             "api_request",
             %{
               "method" => "GET",
               "path" => "/v1/sessions/#{session_id}/publications/#{operation_id}"
             },
             publication_result_key(command)
           ),
         {:ok, %{"operation" => %{"id" => ^operation_id}} = response} <-
           client.bridge.await_command(lookup.id, client.bridge_options) do
      publication_result(client, command, session_id, response)
    else
      {:ok, _other} -> {:error, {:coop_protocol_error, :publication_resource}}
      error -> error
    end
  end

  defp publication_operation(_client, _placement, _command, _session_id, %{
         "method" => "PublishReview",
         "state" => "failed",
         "error_code" => code,
         "error_detail" => detail
       }),
       do: {:error, {:coop_error, 0, code, detail}}

  defp publication_operation(_client, _placement, _command, _session_id, %{
         "method" => "PublishReview",
         "state" => state
       })
       when state in ~w(reserved running uncertain),
       do: {:error, {:coop_unavailable, "Publication has not completed on its owning worker."}}

  defp publication_operation(_client, _placement, _command, _session_id, _response),
    do: {:error, {:coop_protocol_error, :publication_operation}}

  defp publication_result_key(command), do: "ryker:fleet:publication:#{command.id}"

  @impl true
  def submit_turn(client, session_id, key, revision, prompt, schema) do
    submission = %{
      "contract_version" => "work-final-live-v3",
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => schema,
      "prompt" => prompt
    }

    submit_frozen_turn(client, session_id, key, revision, submission, nil, [])
  end

  @impl true
  def submit_frozen_turn(
        client,
        coop_session_id,
        key,
        revision,
        submission,
        controller_tools,
        artifacts
      ) do
    with {:ok, _artifact_refs} <- exact_input_artifacts(submission, artifacts),
         :ok <- optional_controller_tools(controller_tools),
         {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "submit_turn",
        submit_turn_payload(coop_session_id, revision, submission, controller_tools),
        key
      )
    end
  end

  @impl true
  def fence_frozen_turn(
        client,
        coop_session_id,
        key,
        revision,
        submission,
        controller_tools,
        artifacts
      ) do
    with {:ok, _artifact_refs} <- exact_input_artifacts(submission, artifacts),
         :ok <- optional_controller_tools(controller_tools),
         {:ok, session} <- session_by_coop_id(coop_session_id) do
      fence_durable_operation(
        client,
        session,
        key,
        "submit_turn",
        submit_turn_payload(coop_session_id, revision, submission, controller_tools)
      )
    end
  end

  @impl true
  def get_turn(client, coop_session_id, coop_turn_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_turn", %{
        "coop_session_id" => coop_session_id,
        "coop_turn_id" => coop_turn_id
      })
    end
  end

  @impl true
  def cancel_turn(client, coop_session_id, coop_turn_id, key, revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "cancel_turn",
        %{
          "coop_session_id" => coop_session_id,
          "coop_turn_id" => coop_turn_id,
          "expected_revision" => revision
        },
        key
      )
    end
  end

  @impl true
  def close_session(client, coop_session_id, key, revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "close_session",
        %{
          "coop_session_id" => coop_session_id,
          "expected_revision" => revision
        },
        key
      )
    end
  end

  @impl true
  def plan_discard(
        client,
        coop_session_id,
        key,
        expected_revision,
        accept_dirty,
        accept_unmerged
      ) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "plan_discard",
        %{
          "accept_dirty" => accept_dirty,
          "accept_unmerged" => accept_unmerged,
          "coop_session_id" => coop_session_id,
          "expected_revision" => expected_revision
        },
        key
      )
    end
  end

  @impl true
  def discard_session(client, coop_session_id, key, plan_operation_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "discard_session",
        %{
          "coop_session_id" => coop_session_id,
          "plan_operation_id" => plan_operation_id
        },
        key
      )
    end
  end

  @impl true
  def validate_candidate(client, session_id, turn_id, key, sha256, verdict),
    do: validate_frozen_candidate(client, session_id, turn_id, key, 1, sha256, verdict)

  @impl true
  def validate_frozen_candidate(
        client,
        coop_session_id,
        coop_turn_id,
        key,
        attempt,
        sha256,
        verdict
      ) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         {:ok, verdict_name, violations} <- prepare_verdict(verdict) do
      execute(
        client,
        session,
        "validate_candidate",
        %{
          "candidate_attempt" => attempt,
          "candidate_sha256" => sha256,
          "coop_session_id" => coop_session_id,
          "coop_turn_id" => coop_turn_id,
          "verdict" => verdict_name,
          "violations" => violations
        },
        key
      )
    end
  end

  @impl true
  def operation_by_key(client, key) do
    case Repo.one(Command.Query.by_idempotency_key(key)) do
      nil ->
        :not_found

      %Command{status: :succeeded} = command ->
        with {:ok, body} <-
               Bridge.command_response(
                 command,
                 client.bridge_options[:body_root],
                 client.bridge_options[:checkpoint_key]
               ),
             {:ok, operation} <- operation_result(body),
             {:ok, operation} <- reconcile_waiting_operation(client, command, operation, key),
             :ok <- ensure_reconciled_workspace(client, command, operation, key) do
          {:ok, operation}
        end

      %Command{status: status} = command when status in [:queued, :delivered, :acknowledged] ->
        with {:ok, result} <- client.bridge.await_command(command.id, client.bridge_options),
             {:ok, operation} <- operation_result(result),
             :ok <- ensure_reconciled_workspace(client, command, operation, key) do
          {:ok, operation}
        end

      %Command{status: :failed, kind: kind, error: %{"code" => "invalid_command"}} = command
      when kind in ["create_session", "submit_turn"] ->
        {:ok, worker_rejected_operation(command)}

      %Command{placement_id: nil, status: :failed, error: %{"code" => "operation_not_enqueued"}} =
          command ->
        {:ok, worker_rejected_operation(command)}

      %Command{} = command ->
        with %Session{} = session <- Repo.one(Session.Query.by_id(command.session_id)),
             {:ok, result} <-
               execute_read(client, session, "reconcile_operation", %{"operation_key" => key}),
             {:ok, operation} <- operation_result(result),
             :ok <- ensure_reconciled_workspace(client, command, operation, key) do
          {:ok, operation}
        else
          nil -> {:error, {:coop_session_not_found, command.session_id}}
          {:error, _reason} = error -> error
        end
    end
  end

  @impl true
  def get_output_artifact(client, coop_session_id, coop_turn_id, artifact_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         {:ok, %{stored_body: stored, body_ref: reference, headers: headers}} <-
           execute_read(client, session, "get_output_artifact", %{
             "artifact_ref" => artifact_id,
             "coop_session_id" => coop_session_id,
             "coop_turn_id" => coop_turn_id
           }),
         true <- reference["byte_size"] <= 8 * 1_024 * 1_024,
         true <- headers["Etag"] == ~s("#{reference["sha256"]}"),
         {:ok, bytes} <-
           Bodies.read(
             stored,
             client.bridge_options[:checkpoint_key],
             8 * 1_024 * 1_024
           ),
         true <-
           byte_size(bytes) == reference["byte_size"] and
             Crypto.sha256_hex(bytes) == reference["sha256"] do
      {:ok,
       %{
         "id" => artifact_id,
         "data" => bytes,
         "bytes" => reference["byte_size"],
         "sha256" => reference["sha256"],
         "media_type" => headers["Content-Type"]
       }}
    else
      false -> {:error, {:coop_protocol_error, :output_artifact_transfer}}
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :output_artifact_transfer}}
      {:error, _reason} = error -> error
    end
  end

  defp execute(client, session, kind, payload, key),
    do: client.bridge.execute(session, kind, payload, key, client.bridge_options)

  defp execute_read(client, session, kind, payload),
    do: execute(client, session, kind, payload, Command.read_key(kind))

  defp fence_durable_operation(client, session, key, kind, payload) do
    with {:ok, command} <- ControlPlane.fence_command(session, kind, payload, key) do
      fenced_command(client, command, key, payload)
    end
  end

  defp fenced_command(client, command, key, payload) do
    if Commands.local_fence?(command) or command.payload == payload,
      do: operation_by_key(client, key),
      else: {:error, {:coop_worker_command_conflict, key}}
  end

  defp normalize_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) do
      options |> Map.new() |> normalize_options()
    else
      {:error, {:invalid_coop_fleet_client, :options}}
    end
  end

  defp normalize_options(%{} = options) do
    keys = Map.keys(options)

    if keys -- @option_keys == [] and :workspace_ref in keys,
      do: {:ok, options},
      else: {:error, {:invalid_coop_fleet_client, :options}}
  end

  defp normalize_options(_options), do: {:error, {:invalid_coop_fleet_client, :options}}

  defp valid_workspace_ref?(workspace_ref) when is_binary(workspace_ref) do
    String.valid?(workspace_ref) and String.trim(workspace_ref) != "" and
      byte_size(workspace_ref) <= 1_024 and :binary.match(workspace_ref, <<0>>) == :nomatch
  end

  defp valid_workspace_ref?(_workspace_ref), do: false

  # Task offers can span execution generations. A durable key keeps its original
  # session; before enqueue the Work create key names that session and attempt.
  defp create_session_identity(key, task) do
    case Repo.one(Command.Query.by_idempotency_key(key)) do
      %Command{kind: "create_session", session_id: id} ->
        exact_create_task(Repo.one(Session.Query.by_id(id)), task)

      nil ->
        new_create_identity(key, task)

      _other_kind ->
        {:error, {:coop_worker_command_conflict, key}}
    end
  end

  defp new_create_identity(key, task) do
    case Regex.run(~r/\Aryker:work:create:([0-9a-f-]{36}):g([1-9]\d*)\z/, key) do
      [_, id, generation] ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             %Session{} = session <- Repo.one(Session.Query.by_id(id)),
             true <- Integer.to_string(session.create_generation) == generation do
          exact_create_task(session, task)
        else
          _stale -> {:error, {:coop_worker_command_conflict, key}}
        end

      nil ->
        session_by_task_ref(task)
    end
  end

  defp exact_create_task(%Session{} = session, task) do
    if task in [session.external_ref, Session.coop_task_ref(session)],
      do: {:ok, session},
      else: {:error, {:coop_session_not_found, task}}
  end

  defp exact_create_task(_missing, task), do: {:error, {:coop_session_not_found, task}}

  defp session_by_task_ref(task_ref) do
    case Repo.all(Session.Query.by_task_ref(task_ref)) do
      [%Session{} = session] -> {:ok, session}
      _missing_or_ambiguous -> {:error, {:coop_session_not_found, task_ref}}
    end
  end

  defp restore_checkpoint(%Session{generation: 1}), do: {:ok, nil}

  defp restore_checkpoint(%Session{} = session) do
    previous = Repo.one(Session.Query.previous_generation(session))
    checkpoint = Repo.one(WorkspaceCheckpointTransfer.Query.latest_for_replacement(session))

    case checkpoint do
      nil -> missing_checkpoint(previous)
      {checkpoint, source} -> checkpoint_document(checkpoint, source, session)
    end
  end

  # A checkpoint carries the exact tree of the source it was taken from, so it
  # may only seed a replacement pinned to the same repository source. Rotation
  # copies the selector verbatim; a mismatch is a custody violation, never a
  # reason to start from a different source.
  defp checkpoint_document(checkpoint, %Session{} = source, %Session{} = session) do
    if RepositorySource.same?(source.repository_source, session.repository_source) do
      {:ok,
       %{
         "byte_size" => checkpoint.bundle_byte_size,
         "checkpoint_ref" => checkpoint.checkpoint_ref,
         "sha256" => checkpoint.bundle_sha256,
         "source_placement_generation" => checkpoint.placement_generation,
         "source_session_ref" => checkpoint.session_ref,
         "transfer_id" => checkpoint.id
       }}
    else
      {:error, {:coop_workspace_checkpoint_source_mismatch, session.id, session.generation}}
    end
  end

  defp missing_checkpoint(nil), do: {:ok, nil}
  defp missing_checkpoint(%Session{coop_session_id: nil}), do: {:ok, nil}

  defp missing_checkpoint(%Session{} = previous) do
    if workspace_changes_possible?(previous.id),
      do: {:error, {:coop_workspace_checkpoint_required, previous.id, previous.generation}},
      else: {:ok, nil}
  end

  defp workspace_changes_possible?(session_id),
    do: turn_submission_attempted?(session_id) or checkpoint_restore_attempted?(session_id)

  defp turn_submission_attempted?(session_id) do
    session_id
    |> Command.Query.by_session_id()
    |> Command.Query.by_kind("submit_turn")
    |> Repo.exists?()
  end

  defp checkpoint_restore_attempted?(session_id),
    do: Repo.exists?(Command.Query.checkpoint_restores(session_id))

  defp maybe_put_checkpoint(payload, nil), do: payload
  defp maybe_put_checkpoint(payload, checkpoint), do: Map.put(payload, "checkpoint", checkpoint)

  defp session_by_coop_id(coop_session_id) do
    bound =
      Session.Query.all()
      |> Session.Query.by_coop_session_id(coop_session_id)
      |> Session.Query.limit_to(1)

    case Repo.one(bound) do
      %Session{} = session -> {:ok, session}
      nil -> session_by_reconciled_coop_id(coop_session_id)
    end
  end

  defp session_by_reconciled_coop_id(coop_session_id) do
    case reconciled_sessions(coop_session_id) do
      [%Session{} = session] -> {:ok, session}
      [] -> {:error, {:coop_session_not_found, coop_session_id}}
      [_first, _second] -> {:error, {:coop_session_identity_ambiguous, coop_session_id}}
    end
  end

  defp reconciled_sessions(coop_session_id),
    do: Repo.all(Session.Query.reconciled_into(coop_session_id))

  defp operation_result(%{"operation" => operation}) when is_map(operation), do: {:ok, operation}
  defp operation_result(%{"id" => _id} = operation), do: {:ok, operation}
  defp operation_result(_result), do: {:error, {:coop_protocol_error, :operation_resource}}

  defp reconcile_waiting_operation(
         client,
         command,
         %{"state" => state} = operation,
         operation_key
       )
       when state in ["reserved", "running"] do
    case durable_terminal_operation(command, operation, operation_key) do
      {:ok, terminal} ->
        {:ok, terminal}

      :not_found ->
        with :ok <- Bridge.current_command_placement(command),
             %Session{} = session <- Repo.one(Session.Query.by_id(command.session_id)),
             {:ok, result} <-
               execute_read(client, session, "reconcile_operation", %{
                 "operation_key" => operation_key
               }) do
          operation_result(result)
        else
          nil -> {:error, {:coop_session_not_found, command.session_id}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp reconcile_waiting_operation(_client, _command, operation, _operation_key),
    do: {:ok, operation}

  defp ensure_reconciled_workspace(
         client,
         %Command{kind: "create_session", session_id: session_id} = command,
         %{
           "method" => "CreateRemoteSession",
           "resource_id" => coop_session_id,
           "resource_type" => "session",
           "state" => "succeeded"
         },
         create_key
       )
       when is_binary(coop_session_id) do
    case Repo.one(Session.Query.by_id(session_id)) do
      nil ->
        {:error, {:coop_session_not_found, session_id}}

      %Session{workspace_task: nil} ->
        :ok

      %Session{} = session ->
        if durable_workspace_bound?(command, session, coop_session_id) do
          :ok
        else
          ensure_reconciled_workspace_live(
            client,
            command,
            session,
            coop_session_id,
            create_key
          )
        end
    end
  end

  defp ensure_reconciled_workspace(_client, _command, _operation, _create_key), do: :ok

  defp ensure_reconciled_workspace_live(
         client,
         command,
         session,
         coop_session_id,
         create_key
       ) do
    with :ok <- Bridge.current_command_placement(command),
         {:ok, remote} <-
           execute_read(client, session, "get_session", %{
             "coop_session_id" => coop_session_id
           }),
         {:ok, _ensured} <- ensure_workspace(client, session, %{"session" => remote}, create_key) do
      :ok
    end
  end

  defp durable_terminal_operation(command, operation, operation_key) do
    candidate = Repo.one(Command.Query.terminal_reconciliation(command, operation_key))

    with %Command{result: result} <- candidate,
         {:ok, body} <- Bridge.response(result),
         {:ok, terminal} <- operation_result(body),
         true <- same_operation?(operation, terminal) do
      {:ok, terminal}
    else
      _missing_or_mismatch -> :not_found
    end
  end

  defp same_operation?(%{"id" => id, "method" => method}, %{
         "id" => id,
         "method" => method
       })
       when is_binary(id) and is_binary(method),
       do: true

  defp same_operation?(_operation, _terminal), do: false

  defp durable_workspace_bound?(
         %Command{session_id: session_id, placement_generation: placement_generation},
         %Session{id: session_id} = session,
         coop_session_id
       ) do
    match?(
      {:ok, _remote_session},
      durable_ensured_session(session, coop_session_id, placement_generation)
    )
  end

  defp durable_workspace_bound?(_command, _session, _coop_session_id), do: false

  defp durable_prebinding_session(%Session{coop_session_id: nil} = session, coop_session_id),
    do: durable_ensured_session(session, coop_session_id, nil)

  defp durable_prebinding_session(_session, _coop_session_id), do: :not_found

  defp durable_ensured_session(
         %Session{id: session_id, workspace_task: %{"offer_ref" => offer_ref} = workspace_task},
         coop_session_id,
         placement_generation
       ) do
    query = Command.Query.ensured_workspaces(session_id, coop_session_id)

    query =
      if is_integer(placement_generation),
        do: Command.Query.by_placement_generation(query, placement_generation),
        else: query

    query
    |> Repo.all()
    |> Enum.find_value(:not_found, fn
      %Command{
        payload: %{"task" => ^workspace_task},
        result: %{
          "body" => %{
            "session" =>
              %{
                "id" => ^coop_session_id,
                "workspace_task" => %{"offer_ref" => ^offer_ref}
              } = remote_session
          }
        }
      } ->
        {:ok, remote_session}

      _other ->
        false
    end)
  end

  defp durable_ensured_session(_session, _coop_session_id, _placement_generation),
    do: :not_found

  defp prepare_verdict(:accept), do: {:ok, "accept", []}

  defp prepare_verdict({:reject, violations}) when is_list(violations),
    do: {:ok, "reject", violations}

  defp prepare_verdict(_verdict), do: {:error, {:invalid_coop_request, :verdict}}

  defp exact_input_artifacts(%{"input_artifact_refs" => refs}, artifacts)
       when is_list(refs) and is_list(artifacts) do
    with {:ok, expected} <- Artifacts.coop_inputs(refs),
         true <- expected == artifacts do
      {:ok, refs}
    else
      _mismatch -> {:error, :coop_fleet_input_artifact_mismatch}
    end
  end

  defp exact_input_artifacts(_submission, _artifacts),
    do: {:error, :coop_fleet_input_artifact_mismatch}

  defp optional_controller_tools(nil), do: :ok

  defp optional_controller_tools(%{"endpoint" => endpoint, "token" => token} = binding)
       when map_size(binding) == 2 and is_binary(endpoint) and is_binary(token) do
    case URI.parse(endpoint) do
      %URI{
        scheme: "https",
        host: host,
        path: "/v1/state-tools/mcp",
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and byte_size(endpoint) <= 2_048 ->
        if Regex.match?(~r/\A[0-9a-f]{64}[A-Za-z0-9_-]{43}\z/, token),
          do: :ok,
          else: {:error, {:invalid_coop_controller_tools, :fields}}

      _invalid ->
        {:error, {:invalid_coop_controller_tools, :fields}}
    end
  end

  defp optional_controller_tools(_binding),
    do: {:error, {:invalid_coop_controller_tools, :fields}}

  defp maybe_put_controller_tools(document, nil), do: document

  defp maybe_put_controller_tools(document, binding),
    do: Map.put(document, "controller_tools", controller_tools_descriptor(binding))

  # Create and fence build the identical payload, so a fence request hashes the
  # exact selector create would have sent.
  defp create_session_payload(session, policy, task, source) do
    with {:ok, source} <- repository_source(source) do
      create_payload_for_authority(session, policy, task, source)
    end
  end

  defp create_payload_for_authority(
         %Session{worker_job_document: %{} = job, worker_job_digest: digest} = session,
         _policy,
         task,
         _source
       ) do
    with {:ok, _session} <- JobAuthority.validate(session) do
      {:ok, %{"external_ref" => task, "job" => job, "job_digest" => digest}}
    end
  end

  defp create_payload_for_authority(_session, _policy, _task, _source),
    do: {:error, {:coop_fleet_authority_mismatch, :worker_job}}

  defp submit_turn_payload(coop_session_id, revision, submission, controller_tools) do
    %{
      "coop_session_id" => coop_session_id,
      "expected_revision" => revision,
      "submission" => submission,
      "submission_sha256" => CanonicalJSON.worker_digest(submission),
      "turn_ref" => submission["context"]["turn_ref"] || "logical-turn"
    }
    |> maybe_put_controller_tools(controller_tools)
  end

  defp worker_rejected_operation(command) do
    failed_operation(
      command.kind,
      "fleet-command:#{command.id}",
      command.error["code"],
      command.error["detail"]
    )
  end

  defp failed_operation(kind, id, code, detail) do
    %{
      "error_code" => code,
      "error_detail" => detail,
      "id" => id,
      "method" => operation_method(kind),
      "state" => "failed"
    }
  end

  defp operation_method("create_session"), do: "CreateRemoteSession"
  defp operation_method("submit_turn"), do: "SubmitTurn"

  defp controller_tools_descriptor(%{"endpoint" => endpoint, "token" => token}) do
    %{"endpoint" => endpoint, "token_sha256" => Crypto.sha256_hex(token)}
  end
end
