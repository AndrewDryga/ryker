defmodule Ryker.Settings.Import.Document do
  @moduledoc """
  Bounded decoder for the one retired application YAML shape.

  This is the only deliberate old-format boundary the product keeps, and it runs
  only when an operator explicitly invokes the importer. It refuses an oversized
  file, a document that is not a mapping, an unknown or duplicated key at any
  level, a malformed type and a value outside the bound the retired loader
  enforced. Nothing here starts an adapter, reads a secret value or touches the
  process environment: credential *names* are data, credential values are not.

  A decoded section holds exactly the keys the document set and never a default,
  so the importer can tell an explicit choice from an omission and disclose the
  shipped value that now replaces a retired tuning knob.
  """

  @maximum_bytes 512 * 1_024
  @reference ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @adapter_name ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @secret_name ~r/\A[A-Z][A-Z0-9_]{0,127}\z/
  @slack_id ~r/\A[A-Z0-9]{1,255}\z/
  @github_repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @email ~r/\A[^\s@]+@[^\s@]+\z/
  @ten_years 10 * 365 * 86_400
  @identifier 1..9_223_372_036_854_775_807
  @port {:integer, 1..65_535}

  @policy %{
    required: [name: :reference, digest: :digest],
    optional: [authority_digest: :digest]
  }
  @class_policy %{
    required: [policy: :reference, policy_digest: :digest],
    optional: [authority_digest: :digest]
  }
  @class_policies %{
    required: [conversational: :section, standard: :section, deep: :section],
    optional: []
  }
  @work_profile %{
    required: [policy: :reference, policy_digest: :digest, repository_ref: :reference],
    optional: [authority_digest: :digest, class_policies: :section]
  }

  @root %{
    required: [
      version: {:integer, 1..1},
      mode: {:enumeration, ~w(product component)},
      host_ref: :host_ref,
      coop: :section,
      repositories: :section,
      admission: :section,
      work: :section
    ],
    optional: [
      control_plane: :section,
      coop_worker_gateway: :section,
      delivery: :section,
      emisar: :section,
      event_waits: :section,
      github: :section,
      learning: :section,
      model_evals: :section,
      publication: :section,
      repository_sets: :section,
      retention: :section,
      schedules: :section,
      slack: :section,
      state_tools: :section,
      webhooks: :section
    ]
  }

  @flat %{
    admission: %{
      required: [policy: :policy],
      optional: [
        concurrency: {:integer, 1..32},
        decision_timeout_ms: {:integer, 1_000..300_000},
        poll_interval_ms: {:integer, 1..60_000}
      ]
    },
    coop: %{
      required: [],
      optional: [socket: :path, receive_timeout_ms: {:integer, 100..99_999}]
    },
    coop_worker_gateway: %{
      required: [
        port: @port,
        public_url: :origin,
        cacertfile: :path,
        ca_keyfile: :path,
        certfile: :path,
        checkpoint_key_env: :secret_name,
        checkpoint_secret_scan_env: {:list, :secret_name},
        keyfile: :path
      ],
      optional: [ip: :ip, certificate_ttl_seconds: {:integer, 300..604_800}]
    },
    delivery: %{
      required: [],
      optional: [
        action_concurrency: {:integer, 1..30},
        lease_seconds: {:integer, 1..86_400},
        max_attempts: {:integer, 1..1_000},
        message_concurrency: {:integer, 1..31},
        poll_interval_ms: {:integer, 1..60_000},
        reaction_concurrency: {:integer, 1..30},
        retry_base_seconds: {:integer, 1..3_600},
        retry_max_seconds: {:integer, 1..86_400}
      ]
    },
    emisar: %{
      required: [rpc_url: :rpc_url, token_env: :secret_name],
      optional: [
        concurrency: {:integer, 1..32},
        lease_seconds: {:integer, 1..86_400},
        poll_interval_ms: {:integer, 1..60_000},
        poll_seconds: {:integer, 1..3_600},
        receive_timeout_ms: {:integer, 100..60_000},
        retry_base_seconds: {:integer, 1..3_600},
        retry_max_seconds: {:integer, 1..86_400}
      ]
    },
    event_waits: %{required: [], optional: [poll_interval_ms: {:integer, 1..300_000}]},
    learning: %{
      required: [policy: :policy],
      optional: [
        batch_size: {:integer, 1..16},
        concurrency: {:integer, 1..8},
        execution_timeout_seconds: {:integer, 30..1_800},
        maximum_delay_seconds: {:integer, 1..600},
        poll_interval_ms: {:integer, 100..60_000},
        quiet_seconds: {:integer, 0..300}
      ]
    },
    model_evals: %{
      required: [no_tools_policy: :policy, socket: :path, world_policy: :policy],
      optional: [world_baseline_policy: :policy]
    },
    publication: %{
      required: [
        branch_prefix: :git_ref,
        state_dir: :path,
        commit_name: :text,
        commit_email: :email,
        secret_scan_env: {:list, :secret_name}
      ],
      optional: [
        concurrency: {:integer, 1..32},
        followup_interval_seconds: {:integer, 1..86_400},
        lease_seconds: {:integer, 1..86_400},
        poll_interval_ms: {:integer, 1..60_000},
        retry_base_seconds: {:integer, 1..3_600},
        retry_max_seconds: {:integer, 1..86_400}
      ]
    },
    retention: %{
      required: [
        poll_interval_ms: {:integer, 1..3_600_000},
        lease_seconds: {:integer, 1..3_600},
        max_attempts: {:integer, 1..100},
        retry_base_seconds: {:integer, 1..3_600},
        retry_max_seconds: {:integer, 1..86_400},
        closed_session_grace_seconds: {:integer, 0..2_592_000},
        operational_data_seconds: {:integer, 60..@ten_years},
        conversation_memory_seconds: {:integer, 60..@ten_years},
        closed_work_seconds: {:integer, 60..@ten_years},
        episode_history_seconds: {:integer, 60..@ten_years},
        audit_data_seconds: {:integer, 60..@ten_years}
      ],
      optional: [
        batch_limit: {:integer, 1..1_000},
        batch_seconds: {:integer, 1..3_600},
        retained_recheck_seconds: {:integer, 60..2_592_000},
        disposable_bytes_limit: {:integer, 1_048_576..1_099_511_627_776},
        reclaim_target_seconds: {:integer, 60..2_592_000},
        storage_high_watermark_bytes: {:integer, 1_048_576..1_099_511_627_776},
        storage_low_watermark_bytes: {:integer, 1_048_576..1_099_511_627_776},
        storage_reserve_bytes: {:integer, 1_048_576..1_099_511_627_776}
      ]
    },
    schedules: %{
      required: [read_only_policy: :policy, governed_operation_policy: :policy],
      optional: [
        lease_seconds: {:integer, 1..86_400},
        misfire_grace_seconds: {:integer, 0..31_536_000},
        poll_interval_ms: {:integer, 1..60_000},
        retry_base_seconds: {:integer, 1..3_600},
        retry_max_seconds: {:integer, 1..86_400}
      ]
    },
    state_tools: %{required: [port: @port, token_env: :secret_name], optional: [ip: :ip]},
    work: %{
      required: [],
      optional: [
        capability_names: {:list, :reference},
        concurrency: {:integer, 1..32},
        execution: {:enumeration, ~w(direct fleet)},
        poll_interval_ms: {:integer, 1..60_000},
        source_and_action_tools: {:list, :text},
        workspace_ref: :reference
      ]
    },
    control_plane: %{
      required: [port: @port, work_profile: :section],
      optional: [ip: :ip]
    },
    slack: %{
      required: [
        api_url: :text,
        app_token_env: :secret_name,
        bot_token_env: :secret_name,
        default_repository: :reference,
        identity: :section,
        incident_policy: :policy,
        operators: {:list, :slack_id},
        watch_channels: {:list, :slack_id}
      ],
      optional: [
        channel_prefix: {:pattern, ~r/\A[a-z0-9_-]{1,20}\z/},
        handshake_timeout_ms: {:integer, 100..60_000},
        incident_private: :boolean,
        incident_room_interval_ms: {:integer, 1..86_400_000},
        incident_room_reconcile_ms: {:integer, 1_000..86_400_000},
        maximum_open_incidents: {:integer, 1..1_000},
        membership_reconcile_ms: {:integer, 1..86_400_000},
        receive_timeout_ms: {:integer, 100..60_000},
        reconnect_ms: {:integer, 1..60_000},
        task_card_interval_ms: {:integer, 1..86_400_000},
        task_card_reconcile_ms: {:integer, 1_000..86_400_000},
        thread_status_interval_ms: {:integer, 50..60_000}
      ]
    },
    slack_identity: %{
      required: [workspace_ref: :slack_id, bot_ref: :slack_id, bot_user_ref: :slack_id],
      optional: []
    },
    github: %{
      required: [
        api_url: :text,
        app_id: {:integer, @identifier},
        private_key_env: :secret_name,
        webhook_secret_env: :secret_name,
        bindings: :section,
        port: @port
      ],
      optional: [ip: :ip, receive_timeout_ms: {:integer, 100..60_000}]
    },
    github_binding: %{
      required: [
        repository: :reference,
        installation_id: {:integer, @identifier},
        repository_id: {:integer, @identifier},
        responder_actor_id: {:integer, @identifier},
        authorized_actor_ids: {:list, {:integer, @identifier}}
      ],
      optional: [max_body_bytes: {:integer, 1_024..40_000}, repository_context: :reference]
    },
    repository: %{
      required: [
        path: :path,
        github_repository: {:pattern, @github_repository},
        github_binding: :reference,
        base_branch: :git_ref,
        conversation_policy: :policy,
        contributor_policy: :policy,
        schedule_policy: :policy
      ],
      optional: [standard_policy: :policy, deep_policy: :policy]
    },
    repository_set: %{
      required: [
        primary_repository: :reference,
        read_only_repositories: {:list, :reference},
        conversation_policy: :policy,
        contributor_policy: :policy
      ],
      optional: [
        standard_policy: :policy,
        deep_policy: :policy,
        parallel_goal_limit: {:integer, 1..3}
      ]
    },
    webhooks: %{required: [port: @port, routes: :section], optional: [ip: :ip]},
    route: %{
      required: [auth: :section, destination: :section, work_profile: :section],
      optional: [
        adapter: :section,
        max_body_bytes: {:integer, 1_024..40_000},
        max_clock_skew_seconds: {:integer, 1..3_600},
        publication_lifecycle: :section
      ]
    },
    route_auth: %{
      required: [kind: {:enumeration, ~w(bearer hmac_sha256)}, secret_env: :secret_name],
      optional: []
    },
    route_destination: %{
      required: [
        transport: :adapter_name,
        conversation_ref: :text,
        thread_ref: :optional_text
      ],
      optional: []
    },
    route_lifecycle: %{
      required: [
        environments: {:list, :text},
        kinds: {:list, {:enumeration, ~w(deployment terraform)}},
        repositories: {:list, :reference},
        targets: {:list, :text}
      ],
      optional: []
    },
    route_adapter: %{
      required: [kind: {:enumeration, ~w(universal grafana mapped_json)}],
      optional: [group_by_labels: {:list, :text}, mapping: :section]
    },
    route_mapping: %{
      required: [event_id: :text, status: :text, title: :text],
      optional: [
        annotations: :text,
        ends_at: :text,
        incident_id: :text,
        item_id: :text,
        labels: :text,
        revision: :text,
        severity: :text,
        source_url: :text,
        starts_at: :text,
        summary: :text
      ]
    }
  }

  @typedoc "A refusal names the document path and the reason; never the value."
  @type refusal :: %{path: String.t(), reason: atom()}

  @doc """
  Reads one retired configuration document from disk into normalized values.

  The returned map has atom keys and holds only the keys the document set.
  `:fingerprint` is the SHA-256 of the exact bytes read, so a later rerun can
  prove it is the same source without keeping a copy of it.
  """
  @spec read(Path.t()) :: {:ok, map()} | {:error, {:import_refused, [refusal()]}}
  def read(path) do
    bytes = read_bytes!(path)

    {:ok,
     %{
       bytes: byte_size(bytes),
       fingerprint: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
       path: path,
       values: bytes |> parse!() |> object!(@root, "configuration") |> root!()
     }}
  catch
    {:refused, refused_path, reason} ->
      {:error, {:import_refused, [%{path: refused_path, reason: reason}]}}
  end

  defp read_bytes!(path) do
    unless is_binary(path) and Path.type(path) == :absolute,
      do: refused!("configuration", :path_must_be_absolute)

    case File.read(path) do
      {:ok, bytes} -> bounded!(bytes)
      {:error, reason} -> refused!("configuration", reason)
    end
  end

  defp bounded!(bytes) do
    if byte_size(bytes) <= @maximum_bytes and String.valid?(bytes),
      do: bytes,
      else: refused!("configuration", :must_be_bounded_utf8)
  end

  defp parse!(bytes) do
    unique_keys!(bytes)

    case YamlElixir.read_from_string(bytes) do
      {:ok, %{} = decoded} -> decoded
      {:ok, _other} -> refused!("configuration", :must_be_a_mapping)
      {:error, _reason} -> refused!("configuration", :is_not_valid_yaml)
    end
  end

  # YamlElixir resolves a duplicate key to its first occurrence, silently
  # dropping the value an operator most likely meant. Reading the same bytes
  # once more as ordered pairs exposes every repeat before anything is decoded.
  defp unique_keys!(bytes) do
    case YamlElixir.read_from_string(bytes, maps_as_keywords: true) do
      {:ok, pairs} -> repeated!(pairs, "configuration")
      {:error, _reason} -> refused!("configuration", :is_not_valid_yaml)
    end
  end

  defp repeated!(value, path) do
    cond do
      mapping?(value) ->
        keys = Enum.map(value, &elem(&1, 0))
        unless keys == Enum.uniq(keys), do: refused!(path, :has_duplicate_keys)
        Enum.each(value, fn {key, nested} -> repeated!(nested, "#{path}.#{safe(key)}") end)

      is_list(value) ->
        Enum.each(value, &repeated!(&1, path <> "[]"))

      true ->
        :ok
    end
  end

  defp mapping?(value) do
    is_list(value) and value != [] and
      Enum.all?(value, &match?({key, _value} when is_binary(key), &1))
  end

  # Sections --------------------------------------------------------------------

  defp object!(value, schema, path) when is_map(value) do
    fields = schema.required ++ schema.optional
    known = Enum.map(fields, fn {field, _type} -> Atom.to_string(field) end)

    Enum.each(Map.keys(value), fn key ->
      unless key in known, do: refused!("#{path}.#{safe(key)}", :is_not_a_supported_setting)
    end)

    Enum.each(schema.required, fn {field, _type} ->
      unless Map.has_key?(value, Atom.to_string(field)),
        do: refused!("#{path}.#{field}", :is_required)
    end)

    fields
    |> Enum.flat_map(fn {field, type} ->
      case Map.fetch(value, Atom.to_string(field)) do
        :error -> []
        {:ok, supplied} -> [{field, cast!(supplied, type, "#{path}.#{field}")}]
      end
    end)
    |> Map.new()
  end

  defp object!(_value, _schema, path), do: refused!(path, :must_be_a_mapping)

  defp flat!(value, key, path), do: object!(value, Map.fetch!(@flat, key), path)

  defp root!(object) do
    object
    |> nested(:coop, &flat!(&1, :coop, "coop"))
    |> nested(:admission, &flat!(&1, :admission, "admission"))
    |> nested(:work, &flat!(&1, :work, "work"))
    |> nested(:learning, &flat!(&1, :learning, "learning"))
    |> nested(:model_evals, &flat!(&1, :model_evals, "model_evals"))
    |> nested(:retention, &flat!(&1, :retention, "retention"))
    |> nested(:delivery, &flat!(&1, :delivery, "delivery"))
    |> nested(:emisar, &flat!(&1, :emisar, "emisar"))
    |> nested(:event_waits, &flat!(&1, :event_waits, "event_waits"))
    |> nested(:publication, &flat!(&1, :publication, "publication"))
    |> nested(:schedules, &flat!(&1, :schedules, "schedules"))
    |> nested(:state_tools, &flat!(&1, :state_tools, "state_tools"))
    |> nested(:coop_worker_gateway, &flat!(&1, :coop_worker_gateway, "coop_worker_gateway"))
    |> nested(:control_plane, &control_plane!/1)
    |> nested(:repositories, &named!(&1, :repository, "repositories"))
    |> nested(:repository_sets, &named!(&1, :repository_set, "repository_sets"))
    |> nested(:slack, &slack!/1)
    |> nested(:github, &github!/1)
    |> nested(:webhooks, &webhooks!/1)
  end

  defp nested(object, key, decode) do
    case Map.fetch(object, key) do
      :error -> object
      {:ok, value} -> Map.put(object, key, decode.(value))
    end
  end

  defp control_plane!(value) do
    value
    |> flat!(:control_plane, "control_plane")
    |> nested(:work_profile, &work_profile!(&1, "control_plane.work_profile"))
  end

  defp slack!(value) do
    value
    |> flat!(:slack, "slack")
    |> nested(:identity, &flat!(&1, :slack_identity, "slack.identity"))
  end

  defp github!(value) do
    value
    |> flat!(:github, "github")
    |> nested(:bindings, &named!(&1, :github_binding, "github.bindings"))
  end

  defp webhooks!(value) do
    value
    |> flat!(:webhooks, "webhooks")
    |> nested(:routes, &routes!/1)
  end

  defp routes!(value) when is_map(value) and map_size(value) > 0 do
    Map.new(value, fn {name, attributes} ->
      name = name!(name, @adapter_name, "webhooks.routes")
      path = "webhooks.routes.#{name}"

      route =
        attributes
        |> flat!(:route, path)
        |> nested(:auth, &flat!(&1, :route_auth, "#{path}.auth"))
        |> nested(:destination, &flat!(&1, :route_destination, "#{path}.destination"))
        |> nested(:publication_lifecycle, &lifecycle!(&1, "#{path}.publication_lifecycle"))
        |> nested(:work_profile, &work_profile!(&1, "#{path}.work_profile"))
        |> nested(:adapter, &adapter!(&1, "#{path}.adapter"))

      {name, route}
    end)
  end

  defp routes!(_value), do: refused!("webhooks.routes", :must_name_at_least_one_source)

  defp lifecycle!(value, path) do
    scope = flat!(value, :route_lifecycle, path)

    Enum.each(Map.keys(scope), fn field ->
      values = Map.fetch!(scope, field)

      if values == [] or length(values) > 64,
        do: refused!("#{path}.#{field}", :must_be_a_bounded_nonempty_list)
    end)

    Map.new(scope, fn {field, values} -> {field, Enum.sort(values)} end)
  end

  defp adapter!(value, path) do
    adapter = flat!(value, :route_adapter, path)

    case {adapter.kind, Map.has_key?(adapter, :mapping)} do
      {"mapped_json", true} ->
        nested(adapter, :mapping, &flat!(&1, :route_mapping, "#{path}.mapping"))

      {"mapped_json", false} ->
        refused!("#{path}.mapping", :is_required)

      {_preset, true} ->
        refused!("#{path}.mapping", :is_not_a_supported_setting)

      {"universal", false} ->
        if Map.has_key?(adapter, :group_by_labels),
          do: refused!("#{path}.group_by_labels", :is_not_a_supported_setting),
          else: adapter

      {_preset, false} ->
        adapter
    end
  end

  defp work_profile!(value, path) do
    value
    |> object!(@work_profile, path)
    |> nested(:class_policies, &class_policies!(&1, "#{path}.class_policies"))
  end

  defp class_policies!(value, path) do
    value
    |> object!(@class_policies, path)
    |> Map.new(fn {class, policy} ->
      {class, object!(policy, @class_policy, "#{path}.#{class}")}
    end)
  end

  defp named!(value, key, path) when is_map(value) and map_size(value) > 0 do
    schema = Map.fetch!(@flat, key)

    Map.new(value, fn {name, attributes} ->
      name = name!(name, @reference, path)
      {name, object!(attributes, schema, "#{path}.#{name}")}
    end)
  end

  defp named!(_value, _key, path), do: refused!(path, :must_name_at_least_one_entry)

  defp name!(value, pattern, path) do
    if is_binary(value) and Regex.match?(pattern, value),
      do: value,
      else: refused!("#{path}.#{safe(value)}", :does_not_match_the_supported_format)
  end

  # Scalars ----------------------------------------------------------------------

  # A section is decoded by its own named schema once the enclosing object is
  # built, so the generic cast only carries it through.
  defp cast!(value, :section, _path), do: value

  defp cast!(value, {:integer, %{first: minimum, last: maximum}}, path) do
    if is_integer(value) and value >= minimum and value <= maximum,
      do: value,
      else: refused!(path, :must_be_an_integer_in_range)
  end

  defp cast!(value, :boolean, path) do
    if is_boolean(value), do: value, else: refused!(path, :must_be_true_or_false)
  end

  defp cast!(value, {:enumeration, allowed}, path) do
    if value in allowed, do: value, else: refused!(path, :is_not_a_supported_value)
  end

  defp cast!(value, {:list, type}, path) do
    unless is_list(value) and length(value) <= 256,
      do: refused!(path, :must_be_a_bounded_list)

    values = Enum.map(value, &cast!(&1, type, path <> "[]"))
    unless values == Enum.uniq(values), do: refused!(path, :must_not_repeat_an_entry)
    values
  end

  defp cast!(value, {:pattern, pattern}, path), do: matching!(value, pattern, path)
  defp cast!(value, :reference, path), do: matching!(value, @reference, path)
  defp cast!(value, :adapter_name, path), do: matching!(value, @adapter_name, path)
  defp cast!(value, :digest, path), do: matching!(value, @hex64, path)
  defp cast!(value, :secret_name, path), do: matching!(value, @secret_name, path)
  defp cast!(value, :slack_id, path), do: matching!(value, @slack_id, path)
  defp cast!(value, :email, path), do: matching!(value, @email, path)
  defp cast!(value, :policy, path), do: object!(value, @policy, path)

  defp cast!(value, :host_ref, path) do
    if text?(value) and byte_size(value) <= 128 and String.trim(value) == value,
      do: value,
      else: refused!(path, :must_be_a_bounded_identifier)
  end

  defp cast!(value, :path, path) do
    if text?(value) and Path.type(value) == :absolute,
      do: value,
      else: refused!(path, :must_be_an_absolute_path)
  end

  defp cast!(value, :ip, path) do
    with true <- text?(value),
         {:ok, _address} <- :inet.parse_address(String.to_charlist(value)) do
      value
    else
      _invalid -> refused!(path, :must_be_an_ip_address)
    end
  end

  defp cast!(value, :origin, path), do: https!(value, path, :origin)
  defp cast!(value, :rpc_url, path), do: https!(value, path, :path)

  defp cast!(value, :git_ref, path) do
    unsafe =
      not text?(value) or byte_size(value) > 240 or String.starts_with?(value, ["-", "/"]) or
        String.ends_with?(value, ["/", "."]) or
        String.contains?(value, ["..", "@{", " ", "~", "^", ":", "?", "*", "[", "\\"])

    if unsafe, do: refused!(path, :must_be_a_safe_git_ref), else: value
  end

  defp cast!(value, :text, path) do
    if text?(value), do: value, else: refused!(path, :must_be_bounded_text)
  end

  defp cast!(nil, :optional_text, _path), do: nil
  defp cast!(value, :optional_text, path), do: cast!(value, :text, path)

  defp https!(value, path, kind) do
    uri = if text?(value), do: URI.parse(value)

    if https?(uri) and https_path?(uri, kind),
      do: String.trim_trailing(value, "/"),
      else: refused!(path, :must_be_an_https_url)
  end

  defp https?(nil), do: false

  defp https?(uri) do
    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
      Enum.all?([uri.userinfo, uri.query, uri.fragment], &is_nil/1)
  end

  defp https_path?(nil, _kind), do: false
  defp https_path?(uri, :origin), do: uri.path in [nil, "", "/"]
  defp https_path?(uri, :path), do: is_binary(uri.path) and uri.path not in ["", "/"]

  defp matching!(value, pattern, path) do
    if text?(value) and Regex.match?(pattern, value),
      do: value,
      else: refused!(path, :does_not_match_the_supported_format)
  end

  defp text?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      String.trim(value) != "" and not String.contains?(value, [<<0>>, "\n", "\r"])
  end

  defp safe(key) when is_binary(key) and byte_size(key) <= 64, do: key
  defp safe(_key), do: "unnamed"

  defp refused!(path, reason), do: throw({:refused, path, reason})
end
