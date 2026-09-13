defmodule Ryker.Settings.Import do
  @moduledoc """
  The one-time, explicitly invoked import of a retired application YAML.

  `plan/2` is a read-only dry run. It decodes one old document, resolves what
  each surviving key becomes, and returns a redacted semantic plan: the settings
  that will be written and where, the deployment variables the operator must set,
  the credential names the fixed contract remaps, the non-default tuning a
  shipped code default now replaces, the declarations that are retired, the
  effects that change, and the per-channel participation the four old layers
  resolve to. It never writes, never starts an adapter, never contacts a model
  and never reads a secret value: a credential *name* is data, a credential value
  is not, and the process environment is never enumerated.

  `apply_plan/3` writes that plan in one transaction. The installation identity
  comes from the document, so worker, delivery and publication custody keeps the
  `host_ref` it was already keyed under; everything else goes through the
  ordinary typed settings write path, so an import cannot store a value an
  operator could not have saved. The transaction ends with a content-safe receipt
  holding fingerprints and the resulting revision, never a value. An identical
  rerun matches that receipt and reports already applied without a second write;
  a changed source, or a settings revision that moved because someone edited the
  installation afterwards, is a conflict rather than an overwrite of that work.

  This is never a runtime fallback: nothing in startup, readiness or ordinary
  operator tooling reaches it.
  """

  import Ecto.Query

  alias Ryker.{Bootstrap, CanonicalJSON, Defaults, Repo, Settings}
  alias Ryker.Settings.Import.{Document, Participation}
  alias Ryker.Settings.ImportReceipt

  @transports ~w(slack github control_plane)
  # Old section -> the owner in Ryker.Defaults that now ships its tuning.
  @tuning %{
    admission: :admission,
    coop: :coop,
    coop_worker_gateway: :coop_worker_gateway,
    delivery: :delivery,
    emisar: :emisar,
    event_waits: :event_waits,
    github: :github,
    learning: :learning,
    publication: :publication,
    retention: :retention,
    schedules: :schedules,
    slack: :slack,
    work: :work
  }
  # Keys inside those sections that are product settings, deployment inputs or
  # identity rather than tuning, and so are reported by their own destination.
  @not_tuning %{
    admission: ~w(policy)a,
    coop: ~w(socket)a,
    coop_worker_gateway:
      ~w(cacertfile ca_keyfile certfile checkpoint_key_env checkpoint_secret_scan_env ip keyfile port public_url)a,
    emisar: ~w(rpc_url token_env)a,
    github: ~w(api_url app_id bindings ip port private_key_env webhook_secret_env)a,
    learning: ~w(policy)a,
    publication: ~w(branch_prefix commit_email commit_name secret_scan_env state_dir)a,
    retention:
      ~w(audit_data_seconds closed_work_seconds conversation_memory_seconds episode_history_seconds operational_data_seconds)a,
    schedules: ~w(governed_operation_policy read_only_policy)a,
    slack:
      ~w(api_url app_token_env bot_token_env channel_prefix default_repository identity incident_policy incident_private operators watch_channels)a,
    work: ~w(capability_names execution source_and_action_tools workspace_ref)a
  }
  @deployment [
    {[:control_plane, :ip], "RYKER_CONTROL_IP"},
    {[:control_plane, :port], "RYKER_CONTROL_PORT"},
    {[:state_tools, :ip], "RYKER_STATE_TOOLS_IP"},
    {[:state_tools, :port], "RYKER_STATE_TOOLS_PORT"},
    {[:coop_worker_gateway, :ip], "RYKER_WORKER_IP"},
    {[:coop_worker_gateway, :port], "RYKER_WORKER_PORT"},
    {[:coop_worker_gateway, :public_url], "RYKER_WORKER_PUBLIC_URL"},
    {[:coop_worker_gateway, :cacertfile], "RYKER_WORKER_CA_FILE"},
    {[:coop_worker_gateway, :ca_keyfile], "RYKER_WORKER_CA_KEY_FILE"},
    {[:coop_worker_gateway, :certfile], "RYKER_WORKER_CERT_FILE"},
    {[:coop_worker_gateway, :keyfile], "RYKER_WORKER_KEY_FILE"},
    {[:github, :ip], "RYKER_GITHUB_IP"},
    {[:github, :port], "RYKER_GITHUB_PORT"},
    {[:github, :api_url], "GITHUB_API_URL"},
    {[:github, :app_id], "GITHUB_APP_ID"},
    {[:webhooks, :ip], "RYKER_WEBHOOK_IP"},
    {[:webhooks, :port], "RYKER_WEBHOOK_PORT"},
    {[:emisar, :rpc_url], "EMISAR_RPC_URL"},
    {[:publication, :state_dir], "RYKER_STATE_DIR"}
  ]
  @core_secrets [
    {[:slack, :bot_token_env], :slack_bot},
    {[:slack, :app_token_env], :slack_app},
    {[:emisar, :token_env], :emisar},
    {[:github, :private_key_env], :github_private_key},
    {[:github, :webhook_secret_env], :github_webhook},
    {[:coop_worker_gateway, :checkpoint_key_env], :checkpoint},
    {[:state_tools, :token_env], :state_tools}
  ]
  @retirements [
    {[:version], "release and database schema versions are internal"},
    {[:mode], "the execution topology is a build choice, not an operator setting"},
    {[:coop, :socket],
     "a local Coop socket is not a product input; Work, admission and learning run on the enrolled fleet"},
    {[:work, :execution], "fleet execution is fixed for product builds"},
    {[:work, :capability_names], "worker capabilities are verified metadata, not a declaration"},
    {[:work, :source_and_action_tools],
     "the model's tool catalog is verified worker metadata, never a hand-written list"},
    {[:model_evals], "evaluation tooling takes explicit typed policies of its own"},
    {[:slack, :api_url], "the official Slack endpoint ships with the code"},
    {[:coop_worker_gateway, :checkpoint_secret_scan_env],
     "scan secrets are the registered deployment secret set"},
    {[:publication, :secret_scan_env], "scan secrets are the registered deployment secret set"}
  ]

  @scoped_purposes [
    conversational: :conversation_policy,
    standard: :standard_policy,
    deep: :deep_policy,
    contributor: :contributor_policy,
    schedule: :schedule_policy
  ]

  @type refusal :: %{path: String.t(), reason: atom()}

  @doc """
  Reads one retired document and reports exactly what importing it would do.

  Performs no writes. `:status` is `:ready` when the installation can still be
  created, `:already_applied` when a receipt proves this exact source produced
  the current revision, or `{:conflict, reason}` when applying would overwrite
  work that happened after an earlier import.
  """
  @spec plan(Path.t(), Bootstrap.t()) :: {:ok, map()} | {:error, term()}
  def plan(path, %Bootstrap{} = bootstrap) do
    with {:ok, source} <- Document.read(path),
         {:ok, plan} <- analyze(source, bootstrap) do
      {:ok, status(plan)}
    end
  end

  @doc """
  The redacted, printable projection of a plan.

  Drops the decoded document the applier carries — the plan an operator reads is
  the semantic difference, not another copy of the old file — and renders the
  rest as plain JSON values so it can be printed or attached to a runbook.
  """
  @spec document(map()) :: map()
  def document(plan) do
    %{
      "changed_effects" => Settings.stringify(plan.changed_effects),
      "deployment" => Settings.stringify(plan.deployment),
      "host_ref" => plan.host_ref,
      "participation" => %{
        "channels" => Settings.stringify(plan.participation.channels),
        "installation_default" => to_string(plan.participation.installation_default)
      },
      "plan_fingerprint" => plan.plan_fingerprint,
      "receipt" => plan.receipt && Settings.stringify(plan.receipt),
      "replaced_tuning" => Settings.stringify(plan.replaced_tuning),
      "retired" => Settings.stringify(plan.retired),
      "secret_remap" => Settings.stringify(plan.secret_remap),
      "settings" => Settings.stringify(plan.settings),
      "source" => Settings.stringify(plan.source),
      "status" => status_text(plan.status),
      "writes" => Settings.stringify(plan.writes)
    }
  end

  defp status_text({:conflict, reason}), do: "conflict: #{reason}"
  defp status_text(status), do: Atom.to_string(status)

  @doc """
  Applies one retired document atomically.

  Returns `{:ok, %{status: :applied | :already_applied, revision: revision}}`.
  Any refusal, conflict or failure leaves the database exactly as it was.
  """
  @spec apply_plan(Path.t(), Bootstrap.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def apply_plan(path, %Bootstrap{} = bootstrap, actor_ref) do
    with {:ok, plan} <- plan(path, bootstrap), do: write(plan, actor_ref)
  end

  defp write(%{status: :already_applied} = plan, _actor_ref),
    do: {:ok, %{status: :already_applied, revision: plan.receipt.revision, plan: document(plan)}}

  defp write(%{status: {:conflict, reason}}, _actor_ref),
    do: {:error, {:import_conflict, reason}}

  defp write(%{status: :ready} = plan, actor_ref) do
    case Repo.transaction(fn -> write!(plan, actor_ref) end) do
      {:ok, outcome} -> {:ok, Map.put(outcome, :plan, document(plan))}
      {:error, reason} -> {:error, reason}
    end
  end

  # Status and receipts ------------------------------------------------------------

  defp status(plan) do
    receipt =
      Repo.one(from(item in ImportReceipt, order_by: [desc: item.inserted_at], limit: 1))

    case receipt do
      nil ->
        Map.merge(plan, %{status: :ready, receipt: nil})

      receipt ->
        Map.merge(plan, %{status: compare(plan, receipt), receipt: receipt_document(receipt)})
    end
  end

  defp compare(plan, receipt) do
    current = Repo.one(from(installation in Settings.Installation, select: installation.revision))

    cond do
      receipt.source_fingerprint != plan.source.fingerprint -> {:conflict, :source_changed}
      current != receipt.revision -> {:conflict, :target_edited}
      receipt.plan_fingerprint != plan.plan_fingerprint -> {:conflict, :target_edited}
      true -> :already_applied
    end
  end

  defp receipt_document(receipt),
    do: Map.take(receipt, [:actor_ref, :host_ref, :id, :inserted_at, :revision])

  # Plan ----------------------------------------------------------------------------

  defp analyze(source, bootstrap) do
    values = source.values

    case refusals(values, bootstrap) do
      [] -> {:ok, build(source, values)}
      refusals -> {:error, {:import_refused, refusals}}
    end
  end

  defp build(source, values) do
    participation = Participation.resolve(values)

    plan = %{
      changed_effects: changed_effects(values),
      deployment: deployment(values),
      host_ref: values.host_ref,
      participation: participation,
      replaced_tuning: replaced_tuning(values),
      retired: retired(values),
      secret_remap: secret_remap(values),
      settings: settings(values, participation),
      source: Map.take(source, [:bytes, :fingerprint, :path]),
      values: values,
      writes: writes(values)
    }

    Map.put(plan, :plan_fingerprint, CanonicalJSON.digest(fingerprint_document(plan)))
  end

  # Only the semantic result is fingerprinted: the same document read from a
  # different path, or replanned once it is already applied, must produce the
  # same value so a rerun can prove it is the same import.
  defp fingerprint_document(plan) do
    %{
      "changed_effects" => stringify(plan.changed_effects),
      "deployment" => stringify(plan.deployment),
      "host_ref" => plan.host_ref,
      "participation" => %{
        "channels" =>
          plan.participation.channels
          |> Enum.reject(&is_nil(&1.participation))
          |> Enum.map(&%{"channel_ref" => &1.channel_ref, "value" => to_string(&1.participation)}),
        "installation_default" => to_string(plan.participation.installation_default)
      },
      "replaced_tuning" => stringify(plan.replaced_tuning),
      "retired" => stringify(plan.retired),
      "secret_remap" => stringify(plan.secret_remap),
      "settings" => stringify(plan.settings)
    }
  end

  defp stringify(entries), do: Enum.map(entries, &Settings.stringify/1)

  # Refusals --------------------------------------------------------------------------

  defp refusals(values, bootstrap) do
    Enum.sort_by(
      execution_refusals(values) ++
        repository_refusals(values) ++
        github_refusals(values) ++
        profile_refusals(values) ++
        webhook_refusals(values) ++
        secret_refusals(values, bootstrap) ++
        Participation.refusals(values),
      &{&1.path, &1.reason}
    )
  end

  defp execution_refusals(values) do
    slack = Map.get(values, :slack)
    repositories = Map.keys(Map.get(values, :repositories, %{}))
    sets = Map.keys(Map.get(values, :repository_sets, %{}))

    refuse(
      get_in(values, [:work, :execution]) == "direct",
      "work.execution",
      :isolated_topology_is_not_a_product_setting
    ) ++
      refuse(
        slack && slack.api_url != Defaults.fetch!(:slack).api_url,
        "slack.api_url",
        :is_fixed_to_the_official_endpoint
      ) ++
      refuse(
        slack && slack.default_repository in sets,
        "slack.default_repository",
        :must_name_a_repository_not_a_repository_set
      ) ++
      refuse(
        (slack && slack.default_repository not in repositories) and
          slack.default_repository not in sets,
        "slack.default_repository",
        :names_an_unconfigured_repository
      )
  end

  defp repository_refusals(values) do
    repositories = Map.keys(Map.get(values, :repositories, %{}))

    authorities =
      Enum.flat_map(Map.get(values, :repositories, %{}), fn {ref, repository} ->
        authority_refusals(repository, "repositories.#{ref}")
      end) ++
        Enum.flat_map(Map.get(values, :repository_sets, %{}), fn {ref, set} ->
          authority_refusals(set, "repository_sets.#{ref}")
        end)

    sets =
      Enum.flat_map(Map.get(values, :repository_sets, %{}), fn {ref, set} ->
        refuse(
          [set.primary_repository | set.read_only_repositories] -- repositories != [],
          "repository_sets.#{ref}",
          :names_an_unconfigured_repository
        ) ++
          refuse(
            set.primary_repository in set.read_only_repositories,
            "repository_sets.#{ref}.read_only_repositories",
            :must_exclude_the_primary_repository
          )
      end)

    authorities ++ sets
  end

  # The retired loader refused a document whose three work classes did not share
  # one model-independent authority; importing one would widen a grant.
  defp authority_refusals(source, path) do
    conversational = source.conversation_policy
    standard = Map.get(source, :standard_policy, conversational)
    deep = Map.get(source, :deep_policy, standard)

    authorities =
      [conversational, standard, deep] |> Enum.map(&Map.get(&1, :authority_digest)) |> Enum.uniq()

    refuse(length(authorities) > 1, path, :class_policies_must_share_one_authority)
  end

  defp github_refusals(values) do
    case Map.get(values, :github) do
      nil ->
        []

      github ->
        repositories = Map.keys(Map.get(values, :repositories, %{}))
        contexts = context_refs(values)
        bound = Enum.map(github.bindings, fn {_name, binding} -> binding.repository end)

        Enum.flat_map(github.bindings, fn {name, binding} ->
          path = "github.bindings.#{name}"
          declared = get_in(values, [:repositories, binding.repository, :github_binding])

          refuse(
            binding.repository not in repositories,
            "#{path}.repository",
            :names_an_unconfigured_repository
          ) ++
            refuse(
              Enum.count(bound, &(&1 == binding.repository)) > 1,
              "#{path}.repository",
              :is_already_bound_by_another_binding
            ) ++
            refuse(
              declared != nil and declared != name,
              "#{path}.repository",
              :does_not_name_this_binding
            ) ++
            refuse(
              Map.has_key?(binding, :repository_context) and
                binding.repository_context not in contexts,
              "#{path}.repository_context",
              :names_an_unconfigured_context
            )
        end)
    end
  end

  # A work profile is no longer typed into a document: the local console and each
  # webhook source resolve the reviewed policies of one repository context. A
  # profile that does not already equal that resolution cannot be reproduced.
  defp profile_refusals(values) do
    control_plane =
      case Map.get(values, :control_plane) do
        nil ->
          []

        %{work_profile: profile} ->
          refuse(
            profile.repository_ref != context_refs(values) |> Enum.sort() |> List.first(),
            "control_plane.work_profile.repository_ref",
            :is_now_the_first_configured_context
          ) ++ reproducible(values, profile, "control_plane.work_profile")
      end

    routes =
      Enum.flat_map(routes(values), fn {name, route} ->
        reproducible(values, route.work_profile, "webhooks.routes.#{name}.work_profile")
      end)

    control_plane ++ routes
  end

  defp reproducible(values, profile, path) do
    case resolved_profile(values, profile.repository_ref) do
      nil ->
        [%{path: "#{path}.repository_ref", reason: :names_an_unconfigured_context}]

      resolved ->
        if Map.has_key?(profile, :class_policies) do
          refuse(
            profile_document(profile) != resolved,
            path,
            :does_not_match_the_reviewed_policies_of_its_context
          )
        else
          [%{path: path, reason: :must_pin_every_work_class_to_be_reproduced}]
        end
    end
  end

  defp resolved_profile(values, ref) do
    source = get_in(values, [:repositories, ref]) || get_in(values, [:repository_sets, ref])

    if source do
      conversational = source.conversation_policy
      standard = Map.get(source, :standard_policy, conversational)
      deep = Map.get(source, :deep_policy, standard)

      %{
        "authority_digest" => Map.get(conversational, :authority_digest),
        "class_policies" => %{
          "conversational" => class_document(conversational),
          "deep" => class_document(deep),
          "standard" => class_document(standard)
        },
        "policy" => conversational.name,
        "policy_digest" => conversational.digest
      }
    end
  end

  defp class_document(policy) do
    %{
      "authority_digest" => Map.get(policy, :authority_digest),
      "policy" => policy.name,
      "policy_digest" => policy.digest
    }
  end

  defp profile_document(profile) do
    %{
      "authority_digest" => Map.get(profile, :authority_digest),
      "class_policies" =>
        Map.new(profile.class_policies, fn {class, policy} ->
          {Atom.to_string(class),
           %{
             "authority_digest" => Map.get(policy, :authority_digest),
             "policy" => policy.policy,
             "policy_digest" => policy.policy_digest
           }}
        end),
      "policy" => profile.policy,
      "policy_digest" => profile.policy_digest
    }
  end

  defp webhook_refusals(values) do
    contexts = context_refs(values)
    repositories = Map.keys(Map.get(values, :repositories, %{}))

    Enum.flat_map(routes(values), fn {name, route} ->
      path = "webhooks.routes.#{name}"
      lifecycle = Map.get(route, :publication_lifecycle)

      refuse(
        route.destination.transport not in @transports,
        "#{path}.destination.transport",
        :is_not_a_supported_delivery_transport
      ) ++
        refuse(
          route.work_profile.repository_ref not in contexts,
          "#{path}.work_profile.repository_ref",
          :names_an_unconfigured_context
        ) ++
        refuse(
          lifecycle && lifecycle.repositories -- repositories != [],
          "#{path}.publication_lifecycle.repositories",
          :names_an_unconfigured_repository
        )
    end)
  end

  defp secret_refusals(values, bootstrap) do
    Enum.flat_map(custom_secrets(values), fn {path, name} ->
      refuse(
        name not in bootstrap.webhook_secret_names,
        path,
        :is_not_registered_in_ryker_webhook_secret_names
      )
    end)
  end

  defp custom_secrets(values) do
    sources =
      Enum.map(routes(values), fn {name, route} ->
        {"webhooks.routes.#{name}.auth.secret_env", route.auth.secret_env}
      end)

    scans =
      Enum.flat_map(
        [
          {"publication.secret_scan_env", get_in(values, [:publication, :secret_scan_env])},
          {"coop_worker_gateway.checkpoint_secret_scan_env",
           get_in(values, [:coop_worker_gateway, :checkpoint_secret_scan_env])}
        ],
        fn
          {_path, nil} -> []
          {path, names} -> Enum.map(names, &{"#{path}[]", &1})
        end
      )

    Enum.sort(sources ++ scans)
  end

  defp refuse(true, path, reason), do: [%{path: path, reason: reason}]
  defp refuse(_false, _path, _reason), do: []

  # Plan sections -----------------------------------------------------------------------

  defp settings(values, participation) do
    Enum.sort_by(
      retention_settings(values) ++
        slack_settings(values, participation) ++
        work_settings(values) ++
        repository_settings(values) ++
        context_settings(values) ++
        policy_settings(values) ++
        github_settings(values) ++
        publication_settings(values) ++
        service_settings(values) ++
        webhook_settings(values),
      & &1.destination
    )
  end

  # One row per mapped key: the old path, the value, and the exact column.
  defp rows(table, entries) do
    Enum.map(entries, fn {setting, column, value} ->
      %{setting: setting, value: value, destination: "#{table}.#{column}"}
    end)
  end

  defp retention_settings(values) do
    rows(
      "retention_settings",
      Enum.map(retention(values), fn {field, value} -> {"retention.#{field}", field, value} end)
    )
  end

  defp slack_settings(values, participation) do
    case Map.get(values, :slack) do
      nil ->
        []

      slack ->
        identity = slack.identity
        prefix = Map.get(slack, :channel_prefix, "ems")
        private = Map.get(slack, :incident_private, true)

        rows("slack_settings", [
          {"slack", :enabled, true},
          {"slack.identity.workspace_ref", :workspace_ref, identity.workspace_ref},
          {"slack.identity.bot_ref", :bot_ref, identity.bot_ref},
          {"slack.identity.bot_user_ref", :bot_user_ref, identity.bot_user_ref},
          {"slack.default_repository", :default_repository_ref, slack.default_repository},
          {"slack.operators", :operators, slack.operators},
          {"slack.channel_prefix", :channel_prefix, prefix},
          {"slack.incident_private", :incident_private, private},
          {"slack.watch_channels", :default_participation, participation.installation_default}
        ])
    end
  end

  defp work_settings(values) do
    case get_in(values, [:work, :workspace_ref]) do
      nil -> []
      ref -> rows("work_settings", [{"work.workspace_ref", :workspace_ref, ref}])
    end
  end

  defp repository_settings(values) do
    Enum.flat_map(Map.get(values, :repositories, %{}), fn {ref, repository} ->
      old = "repositories.#{ref}"

      rows("repository_settings[#{ref}]", [
        {"#{old}.github_repository", :github_repository, repository.github_repository},
        {"#{old}.base_branch", :base_branch, repository.base_branch},
        {"#{old}.path", :publication_checkout_path, repository.path}
      ])
    end)
  end

  defp context_settings(values) do
    Enum.flat_map(Map.get(values, :repository_sets, %{}), fn {ref, set} ->
      old = "repository_sets.#{ref}"
      companions = set.read_only_repositories
      limit = Map.get(set, :parallel_goal_limit, 3)

      rows("repository_context_settings[#{ref}]", [
        {"#{old}.primary_repository", :primary_repository_ref, set.primary_repository},
        {"#{old}.read_only_repositories", :read_only_repository_refs, companions},
        {"#{old}.parallel_goal_limit", :parallel_goal_limit, limit}
      ])
    end)
  end

  defp policy_settings(values) do
    Enum.map(policy_bindings(values), fn binding ->
      %{
        setting: binding.setting,
        value: binding.policy_name,
        destination:
          "policy_bindings[#{binding.purpose}@#{binding.scope_kind}:#{binding.scope_ref}]"
      }
    end)
  end

  defp policy_bindings(values) do
    installation =
      [
        {:admission, [:admission, :policy]},
        {:learning, [:learning, :policy]},
        {:incident, [:slack, :incident_policy]},
        {:schedule_read_only, [:schedules, :read_only_policy]},
        {:schedule_governed, [:schedules, :governed_operation_policy]}
      ]
      |> Enum.flat_map(fn {purpose, path} ->
        case get_in(values, path) do
          nil -> []
          policy -> [binding(purpose, :installation, "", policy, Enum.join(path, "."))]
        end
      end)

    scoped =
      (Enum.map(Map.get(values, :repositories, %{}), &{:repository, "repositories", &1}) ++
         Enum.map(Map.get(values, :repository_sets, %{}), &{:context, "repository_sets", &1}))
      |> Enum.flat_map(&scoped_bindings/1)

    Enum.sort_by(installation ++ scoped, &{&1.scope_kind, &1.scope_ref, &1.purpose})
  end

  defp scoped_bindings({scope_kind, prefix, {ref, source}}) do
    Enum.flat_map(@scoped_purposes, fn {purpose, field} ->
      case Map.get(source, field) do
        nil -> []
        policy -> [binding(purpose, scope_kind, ref, policy, "#{prefix}.#{ref}.#{field}")]
      end
    end)
  end

  defp binding(purpose, scope_kind, scope_ref, policy, setting) do
    %{
      authority_digest: Map.get(policy, :authority_digest),
      policy_digest: policy.digest,
      policy_name: policy.name,
      purpose: purpose,
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      setting: setting
    }
  end

  defp github_settings(values) do
    case Map.get(values, :github) do
      nil ->
        []

      github ->
        rows("github_settings", [
          {"github", :enabled, true},
          {"github.app_id", :app_id, github.app_id}
        ]) ++ Enum.flat_map(github.bindings, &github_binding_settings/1)
    end
  end

  defp github_binding_settings({name, binding}) do
    old = "github.bindings.#{name}"

    rows("github_binding_settings[#{name}]", [
      {"#{old}.repository", :repository_ref, binding.repository},
      {"#{old}.installation_id", :installation_id, binding.installation_id},
      {"#{old}.repository_id", :repository_id, binding.repository_id},
      # The retired document names the app's own actor by the pre-rename key;
      # the setting that now carries it is ryker_actor_id.
      {"#{old}.responder_actor_id", :ryker_actor_id, binding.responder_actor_id},
      {"#{old}.authorized_actor_ids", :authorized_actor_ids, binding.authorized_actor_ids}
    ])
  end

  defp publication_settings(values) do
    case Map.get(values, :publication) do
      nil ->
        []

      publication ->
        rows("publication_settings", [
          {"publication", :enabled, Map.has_key?(values, :github)},
          {"publication.branch_prefix", :branch_prefix, publication.branch_prefix},
          {"publication.commit_name", :commit_name, publication.commit_name},
          {"publication.commit_email", :commit_email, publication.commit_email}
        ])
    end
  end

  defp service_settings(values) do
    [:emisar, :learning]
    |> Enum.filter(&Map.has_key?(values, &1))
    |> Enum.flat_map(&rows("#{&1}_settings", [{Atom.to_string(&1), :enabled, true}]))
  end

  defp webhook_settings(values) do
    Enum.flat_map(routes(values), fn {name, route} ->
      old = "webhooks.routes.#{name}"
      destination = route.destination

      rows("webhook_source_settings[#{name}]", [
        {"#{old}.adapter.kind", :adapter_kind, adapter(route).kind},
        {"#{old}.auth.kind", :auth_kind, route.auth.kind},
        {"#{old}.auth.secret_env", :secret_name, route.auth.secret_env},
        {"#{old}.destination.transport", :destination_transport, destination.transport},
        {"#{old}.destination.conversation_ref", :destination_conversation_ref,
         destination.conversation_ref},
        {"#{old}.work_profile.repository_ref", :context_ref, route.work_profile.repository_ref}
      ])
    end)
  end

  defp deployment(values) do
    @deployment
    |> Enum.flat_map(fn {path, variable} ->
      case get_in(values, path) do
        nil -> []
        value -> [%{setting: Enum.join(path, "."), value: value, variable: variable}]
      end
    end)
    |> Enum.sort_by(& &1.variable)
  end

  defp secret_remap(values) do
    core =
      Enum.flat_map(@core_secrets, fn {path, kind} ->
        case get_in(values, path) do
          nil -> []
          name -> [%{setting: Enum.join(path, "."), from: name, to: fixed_secret_name(kind)}]
        end
      end)

    custom =
      Enum.map(custom_secrets(values), fn {path, name} ->
        %{setting: path, from: name, to: "#{name} (registered in RYKER_WEBHOOK_SECRET_NAMES)"}
      end)

    Enum.sort_by(core ++ custom, & &1.setting)
  end

  # The fixed names come from the bootstrap contract itself, so a remap can never
  # print a variable the runtime does not actually read: asked for a credential
  # the environment does not supply, the provider reports the exact name it read.
  defp fixed_secret_name(kind) do
    {:error, {:environment_variable_missing, name}} =
      Bootstrap.token_provider(kind, fn _name -> :error end).()

    name
  end

  defp replaced_tuning(values) do
    sections =
      Enum.flat_map(@tuning, fn {section, owner} ->
        shipped = Defaults.fetch!(owner)
        excluded = Map.get(@not_tuning, section, [])

        values
        |> Map.get(section, %{})
        |> Enum.flat_map(fn {field, value} ->
          replaced("#{section}.#{field}", field, value, shipped, owner, excluded)
        end)
      end)

    nested =
      Enum.flat_map(routes(values), fn {name, route} ->
        Enum.flat_map(~w(max_body_bytes max_clock_skew_seconds)a, fn field ->
          replaced(
            "webhooks.routes.#{name}.#{field}",
            field,
            Map.get(route, field),
            Defaults.fetch!(:webhooks),
            :webhooks,
            []
          )
        end)
      end) ++
        Enum.flat_map(get_in(values, [:github, :bindings]) || %{}, fn {name, binding} ->
          replaced(
            "github.bindings.#{name}.max_body_bytes",
            :max_body_bytes,
            Map.get(binding, :max_body_bytes),
            Defaults.fetch!(:github),
            :github,
            []
          )
        end)

    Enum.sort_by(sections ++ nested, & &1.setting)
  end

  defp replaced(setting, field, value, shipped, owner, excluded) do
    with false <- field in excluded,
         false <- is_nil(value),
         {:ok, ships} <- Map.fetch(shipped, field),
         true <- ships != value do
      [
        %{
          setting: setting,
          value: value,
          shipped: ships,
          owner: "Ryker.Defaults #{inspect(owner)}"
        }
      ]
    else
      _same_or_unowned -> []
    end
  end

  defp retired(values) do
    declared =
      Enum.flat_map(@retirements, fn {path, why} ->
        case get_in(values, path) do
          nil -> []
          value -> [%{setting: Enum.join(path, "."), value: value, why: why}]
        end
      end)

    bindings =
      Enum.flat_map(Map.get(values, :repositories, %{}), fn {ref, repository} ->
        if get_in(values, [:github, :bindings, repository.github_binding]) do
          []
        else
          [
            %{
              setting: "repositories.#{ref}.github_binding",
              value: repository.github_binding,
              why:
                "the document declares no matching github binding, so the name was already inert"
            }
          ]
        end
      end)

    Enum.sort_by(declared ++ bindings, & &1.setting)
  end

  defp changed_effects(values) do
    component =
      if Map.get(values, :mode) == "component" do
        [
          %{
            setting: "mode",
            detail:
              "component mode ran admission and background learning through the local Coop socket; both now run on the enrolled worker workspace that already runs Work"
          }
        ]
      else
        []
      end

    console =
      if Map.has_key?(values, :control_plane) do
        [
          %{
            setting: "control_plane.work_profile",
            detail:
              "the local console resolves the reviewed policies of its repository context instead of a profile typed into a document"
          }
        ]
      else
        []
      end

    # A retired publication section without GitHub credentials published nothing,
    # because the publisher's repository allowlist was empty. Importing it as
    # connected would claim an authority the installation never had.
    publication =
      if Map.has_key?(values, :publication) and not Map.has_key?(values, :github) do
        [
          %{
            setting: "publication",
            detail:
              "the retired document declared publication without a GitHub App, so no pull request could be published; publication stays disconnected until GitHub is connected"
          }
        ]
      else
        []
      end

    component ++
      console ++
      publication ++
      [
        %{
          setting: "report.weekly_self_report",
          detail:
            "the weekly report is a new opt-in setting and stays disabled; the retired document had no equivalent"
        }
      ]
  end

  defp writes(values) do
    %{
      github_bindings: map_size(get_in(values, [:github, :bindings]) || %{}),
      policy_bindings: length(policy_bindings(values)),
      repositories: map_size(Map.get(values, :repositories, %{})),
      repository_contexts: map_size(Map.get(values, :repository_sets, %{})),
      webhook_sources: map_size(Map.new(routes(values)))
    }
  end

  defp retention(values) do
    horizons = Map.get(values, :retention)

    Map.new(Settings.retention_defaults(), fn {field, shipped} ->
      {field, (horizons && Map.fetch!(horizons, field)) || shipped}
    end)
  end

  defp routes(values), do: Enum.sort(Map.get(values, :webhooks, %{routes: %{}}).routes)

  defp adapter(route), do: Map.get(route, :adapter, %{kind: "universal"})

  defp context_refs(values) do
    Map.keys(Map.get(values, :repositories, %{})) ++
      Map.keys(Map.get(values, :repository_sets, %{}))
  end

  # Apply --------------------------------------------------------------------------------

  defp write!(plan, actor_ref) do
    values = plan.values
    participation = Participation.resolve(values)

    # The plan was built before the transaction opened. Anything that moved since
    # would make the receipt describe an import that did not happen.
    unless participation == plan.participation,
      do: Repo.rollback({:import_failed, :participation_changed})

    revision =
      plan.host_ref
      |> Settings.import_installation(actor_ref, %{retention: retention(values)})
      |> revision!()
      |> write_repositories!(values, actor_ref)
      |> write_contexts!(values, actor_ref)
      |> write_policies!(values, actor_ref)
      |> write_github_bindings!(values, actor_ref)
      |> write_singletons!(values, participation, actor_ref)
      |> write_webhooks!(values, actor_ref)

    Participation.fold!(values, participation)
    receipt = insert_receipt!(plan, actor_ref, revision)
    %{status: :applied, revision: revision, receipt_id: receipt.id}
  end

  defp revision!({:ok, snapshot}), do: snapshot.installation.revision
  defp revision!({:error, reason}), do: Repo.rollback({:import_failed, reason})

  defp write_repositories!(revision, values, actor_ref) do
    values
    |> Map.get(:repositories, %{})
    |> Enum.sort()
    |> Enum.reduce(revision, fn {ref, repository}, revision ->
      %{
        base_branch: repository.base_branch,
        github_repository: repository.github_repository,
        publication_checkout_path: repository.path,
        ref: ref
      }
      |> Settings.put_repository(revision, actor_ref)
      |> revision!()
    end)
  end

  defp write_contexts!(revision, values, actor_ref) do
    values
    |> Map.get(:repository_sets, %{})
    |> Enum.sort()
    |> Enum.reduce(revision, fn {ref, set}, revision ->
      %{
        parallel_goal_limit: Map.get(set, :parallel_goal_limit, 3),
        primary_repository_ref: set.primary_repository,
        read_only_repository_refs: set.read_only_repositories,
        ref: ref
      }
      |> Settings.put_repository_context(revision, actor_ref)
      |> revision!()
    end)
  end

  defp write_policies!(revision, values, actor_ref) do
    Enum.reduce(policy_bindings(values), revision, fn binding, revision ->
      %{
        authority_digest: binding.authority_digest,
        policy_digest: binding.policy_digest,
        policy_name: binding.policy_name,
        purpose: binding.purpose,
        scope_kind: binding.scope_kind,
        scope_ref: binding.scope_ref,
        verified_by: :import
      }
      |> Settings.put_policy_binding(revision, actor_ref)
      |> revision!()
    end)
  end

  defp write_github_bindings!(revision, values, actor_ref) do
    (get_in(values, [:github, :bindings]) || %{})
    |> Enum.sort()
    |> Enum.reduce(revision, fn {name, binding}, revision ->
      %{
        authorized_actor_ids: binding.authorized_actor_ids,
        installation_id: binding.installation_id,
        name: name,
        repository_context_ref: Map.get(binding, :repository_context),
        repository_id: binding.repository_id,
        repository_ref: binding.repository,
        ryker_actor_id: binding.responder_actor_id
      }
      |> Settings.put_github_binding(revision, actor_ref)
      |> revision!()
    end)
  end

  defp write_singletons!(revision, values, participation, actor_ref) do
    [
      {&Settings.save_github/3, github_attributes(values)},
      {&Settings.save_slack/3, slack_attributes(values, participation)},
      {&Settings.save_publication/3, publication_attributes(values)},
      {&Settings.save_emisar/3, enabled_attributes(values, :emisar)},
      {&Settings.save_learning/3, enabled_attributes(values, :learning)},
      {&Settings.save_work/3, work_attributes(values)}
    ]
    |> Enum.reduce(revision, fn
      {_save, nil}, revision -> revision
      {save, attributes}, revision -> save.(attributes, revision, actor_ref) |> revision!()
    end)
  end

  defp github_attributes(values) do
    case Map.get(values, :github) do
      nil -> nil
      github -> %{app_id: github.app_id, enabled: true}
    end
  end

  defp slack_attributes(values, participation) do
    case Map.get(values, :slack) do
      nil ->
        nil

      slack ->
        %{
          bot_ref: slack.identity.bot_ref,
          bot_user_ref: slack.identity.bot_user_ref,
          channel_prefix: Map.get(slack, :channel_prefix, "ems"),
          default_participation: participation.installation_default,
          default_repository_ref: slack.default_repository,
          enabled: true,
          incident_private: Map.get(slack, :incident_private, true),
          operators: slack.operators,
          workspace_ref: slack.identity.workspace_ref
        }
    end
  end

  defp publication_attributes(values) do
    case Map.get(values, :publication) do
      nil ->
        nil

      publication ->
        %{
          branch_prefix: publication.branch_prefix,
          commit_email: publication.commit_email,
          commit_name: publication.commit_name,
          enabled: Map.has_key?(values, :github)
        }
    end
  end

  defp enabled_attributes(values, section) do
    if Map.has_key?(values, section), do: %{enabled: true}
  end

  defp work_attributes(values) do
    case get_in(values, [:work, :workspace_ref]) do
      nil -> nil
      ref -> %{workspace_ref: ref}
    end
  end

  defp write_webhooks!(revision, values, actor_ref) do
    Enum.reduce(routes(values), revision, fn {name, route}, revision ->
      name
      |> webhook_attributes(route)
      |> Settings.put_webhook_source(revision, actor_ref)
      |> revision!()
    end)
  end

  defp webhook_attributes(name, route) do
    adapter = adapter(route)

    %{
      adapter_kind: String.to_existing_atom(adapter.kind),
      auth_kind: String.to_existing_atom(route.auth.kind),
      context_ref: route.work_profile.repository_ref,
      destination_conversation_ref: route.destination.conversation_ref,
      destination_thread_ref: Map.get(route.destination, :thread_ref),
      destination_transport: route.destination.transport,
      enabled: true,
      group_by_labels: Map.get(adapter, :group_by_labels, []),
      mapping: mapping(adapter),
      name: name,
      publication_lifecycle: lifecycle(route),
      secret_name: route.auth.secret_env
    }
  end

  defp mapping(%{mapping: mapping}),
    do: Map.new(mapping, fn {field, path} -> {Atom.to_string(field), path} end)

  defp mapping(_adapter), do: nil

  defp lifecycle(route) do
    case Map.get(route, :publication_lifecycle) do
      nil -> nil
      scope -> Map.new(scope, fn {field, values} -> {Atom.to_string(field), values} end)
    end
  end

  defp insert_receipt!(plan, actor_ref, revision) do
    Repo.insert!(%ImportReceipt{
      actor_ref: actor_ref,
      host_ref: plan.host_ref,
      id: Ecto.UUID.generate(),
      inserted_at: DateTime.utc_now(),
      plan_fingerprint: plan.plan_fingerprint,
      revision: revision,
      source_fingerprint: plan.source.fingerprint
    })
  end
end
