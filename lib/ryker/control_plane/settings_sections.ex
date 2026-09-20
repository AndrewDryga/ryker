defmodule Ryker.ControlPlane.SettingsSections do
  @moduledoc """
  The editable product settings as data: which sections exist, which typed
  fields each one writes, and how a submitted form becomes typed attributes.

  The catalog is deliberately explicit. A generic settings bag would let a form
  write a column nobody reviewed; here every control names a field that the
  settings changeset already validates, and anything the form cannot type
  (a policy digest, a worker advertisement, a credential value) is not here.
  """

  alias Ryker.Settings.{
    GitHub,
    GitHubBinding,
    Learning,
    PolicyBinding,
    PricingRate,
    Publication,
    Report,
    Repository,
    RepositoryContext,
    Slack,
    WebhookSource,
    Work
  }

  alias Ryker.Webhooks.Presets

  @day 86_400
  @participation [
    {"mentions", "Only when mentioned"},
    {"proactive", "Join relevant conversations"},
    {"shadow", "Observe silently"}
  ]
  @purposes [
    {"admission", "Admission (installation)"},
    {"learning", "Learning (installation)"},
    {"incident", "Incident rooms (installation)"},
    {"schedule_read_only", "Scheduled read-only (installation)"},
    {"schedule_governed", "Scheduled governed operation (installation)"},
    {"conversational", "Conversational"},
    {"standard", "Standard work"},
    {"deep", "Deep work"},
    {"contributor", "Contributor (writes)"},
    {"schedule", "Schedule (repository)"}
  ]
  @auth_kinds [
    {"hmac_sha256", "Signed request (HMAC SHA-256)"},
    {"bearer", "Bearer token"}
  ]
  @transports [
    {"slack", "Slack"},
    {"github", "GitHub"},
    {"control_plane", "Direct conversation"}
  ]
  @mapping_fields ~w(event_id status title severity summary source_url starts_at ends_at incident_id item_id labels annotations revision)
  @lifecycle_fields ~w(environments kinds repositories targets)
  @scope_kinds [
    {"installation", "This installation"},
    {"repository", "One repository"},
    {"context", "One repository context"}
  ]
  @weekdays [
    {"1", "Monday"},
    {"2", "Tuesday"},
    {"3", "Wednesday"},
    {"4", "Thursday"},
    {"5", "Friday"},
    {"6", "Saturday"},
    {"7", "Sunday"}
  ]

  @sections [
    %{
      key: :slack,
      domain: :slack,
      kind: :singleton,
      schema: Slack,
      title: "Slack",
      description: "Choose how Ryker participates after the verified Slack connection is ready.",
      fields: [
        %{
          name: :enabled,
          kind: :boolean,
          label: "Use this Slack connection",
          group: "Connection"
        },
        %{
          name: :default_repository_ref,
          kind: :select,
          label: "Default repository",
          options: :repositories,
          group: "Channel defaults",
          help: "Used by channels that have not chosen their own repository context."
        },
        %{
          name: :default_participation,
          kind: :select,
          label: "Default participation",
          options: @participation,
          group: "Channel defaults",
          help:
            "Applies to every channel that has not chosen for itself. " <>
              "Channels with their own choice keep it."
        },
        %{
          name: :channel_prefix,
          kind: :text,
          label: "Incident channel prefix",
          group: "Incident rooms"
        },
        %{
          name: :incident_private,
          kind: :boolean,
          label: "Create incident channels private",
          group: "Incident rooms"
        }
      ]
    },
    %{
      key: :github,
      domain: :github,
      kind: :singleton,
      schema: GitHub,
      title: "GitHub",
      description: "Use the verified GitHub App and choose its API endpoint.",
      fields: [
        %{name: :enabled, kind: :boolean, label: "Use this GitHub App"},
        %{name: :api_url, kind: :text, label: "GitHub API URL"}
      ]
    },
    %{
      key: :publication,
      domain: :publication,
      kind: :singleton,
      schema: Publication,
      title: "Publication",
      description:
        "Identity used for published branches and commits. Changing the branch prefix does " <>
          "not move branches that already exist; their pull requests keep their namespace.",
      fields: [
        %{
          name: :enabled,
          kind: :boolean,
          label: "Publish pull requests",
          help: "Requires a connected GitHub App."
        },
        %{name: :branch_prefix, kind: :text, label: "Branch prefix"},
        %{name: :commit_name, kind: :text, label: "Commit author name"},
        %{name: :commit_email, kind: :text, label: "Commit author email"}
      ]
    },
    %{
      key: :report,
      domain: :report,
      kind: :singleton,
      schema: Report,
      title: "Weekly report",
      description:
        "One recurring self report on the existing schedule boundary. " <>
          "New installations start with it off.",
      fields: [
        %{name: :weekly_self_report_enabled, kind: :boolean, label: "Post a weekly report"},
        %{name: :channel_ref, kind: :text, label: "Channel ID", placeholder: "C0123456789"},
        %{name: :weekday, kind: :select, label: "Day", options: @weekdays},
        %{name: :local_time, kind: :time, label: "Local time"},
        %{
          name: :timezone,
          kind: :text,
          label: "Time zone",
          help: "An IANA name such as Europe/Berlin. The post follows that zone across DST."
        }
      ]
    },
    %{
      key: :learning,
      domain: :learning,
      kind: :singleton,
      schema: Learning,
      title: "Learning",
      description:
        "Model-based background learning. Turning it off pauses new batches; " <>
          "batches already running finish, and durable budgets are not reset. " <>
          "Deterministic memory compaction is mandatory and runs either way.",
      fields: [%{name: :enabled, kind: :boolean, label: "Learn from past conversations"}]
    },
    %{
      key: :repositories,
      domain: :repositories,
      kind: :collection,
      schema: Repository,
      item_key: :ref,
      title: "Repositories",
      description:
        "The repositories this installation works in. A repository is a name plus the metadata " <>
          "Ryker shows; the worker owns the checkout, and selecting one here never grants " <>
          "access to a path the fleet does not already serve.",
      fields: [
        %{name: :ref, kind: :text, label: "Reference", identity: true},
        %{name: :display_name, kind: :text, label: "Display name"},
        %{name: :description, kind: :text, label: "Description"},
        %{
          name: :github_repository,
          kind: :text,
          label: "GitHub repository",
          placeholder: "owner/name"
        },
        %{name: :base_branch, kind: :text, label: "Base branch"},
        %{
          name: :publication_checkout_path,
          kind: :text,
          label: "Publication checkout",
          help:
            "Absolute path of the host checkout used to publish. A repository without one is " <>
              "still a valid context; it simply cannot be published from."
        }
      ]
    },
    %{
      key: :contexts,
      domain: :repositories,
      kind: :collection,
      schema: RepositoryContext,
      item_key: :ref,
      title: "Repository contexts",
      description:
        "A context is one primary repository plus read-only companions, referenced by Slack, " <>
          "GitHub, webhooks and direct conversations. Its goal limit may lower, never raise, the host maximum.",
      fields: [
        %{name: :ref, kind: :text, label: "Reference", identity: true},
        %{name: :display_name, kind: :text, label: "Display name"},
        %{
          name: :primary_repository_ref,
          kind: :select,
          label: "Primary repository",
          options: :repositories
        },
        %{
          name: :read_only_repository_refs,
          kind: :list,
          label: "Read-only companions",
          help: "Mounted for reading only. The primary cannot also be a companion."
        },
        %{name: :parallel_goal_limit, kind: :integer, label: "Parallel goals"}
      ]
    },
    %{
      key: :github_bindings,
      domain: :github,
      kind: :collection,
      schema: GitHubBinding,
      item_key: :name,
      title: "GitHub repository bindings",
      description:
        "The exact verified installation identity for one repository. People with write " <>
          "access to that repository can ask Ryker to work there.",
      fields: [
        %{name: :name, kind: :text, label: "Binding name", identity: true},
        %{name: :repository_ref, kind: :select, label: "Repository", options: :repositories},
        %{name: :installation_id, kind: :integer, label: "Installation ID"},
        %{name: :repository_id, kind: :integer, label: "Repository ID"},
        %{name: :ryker_actor_id, kind: :integer, label: "Ryker actor ID"},
        %{
          name: :repository_context_ref,
          kind: :select,
          label: "Context",
          options: :contexts,
          help: "Optional. Must be a context whose primary is this repository."
        }
      ]
    },
    %{
      key: :policies,
      domain: :policies,
      kind: :collection,
      schema: PolicyBinding,
      item_key: :id,
      row_status: {Ryker.Settings.WorkerPolicies, :binding_status},
      title: "Execution policies",
      description:
        "Advanced only: choose which reviewed worker policy runs each kind of work. " <>
          "The bundled worker supplies these automatically.",
      fields: [
        %{name: :purpose, kind: :select, label: "Purpose", options: @purposes},
        %{name: :scope_kind, kind: :select, label: "Scope", options: @scope_kinds},
        %{
          name: :scope_ref,
          kind: :select,
          label: "Scope reference",
          options: :scopes,
          blank: "",
          help: "Leave unset for an installation-wide purpose."
        },
        %{
          name: :policy_name,
          kind: :select,
          label: "Worker policy",
          options: :advertised_policies,
          help: "Only policies an enrolled, unrevoked worker advertises can be selected."
        },
        %{name: :policy_digest, kind: :evidence, label: "Pinned digest"}
      ]
    },
    %{
      key: :webhooks,
      domain: :webhooks,
      kind: :collection,
      schema: WebhookSource,
      item_key: :name,
      title: "Webhook sources",
      description:
        "Choose what events to accept, how to verify them, and where Ryker should send the work.",
      fields: [
        %{name: :name, kind: :text, label: "Source name", identity: true, group: "Source"},
        %{name: :enabled, kind: :boolean, label: "Accept events", group: "Source"},
        %{
          name: :adapter_kind,
          kind: :select,
          label: "Payload shape",
          group: "Source",
          options: :webhook_presets,
          help: "A preset fills in the shape and grouping; it never chooses the destination."
        },
        %{
          name: :auth_kind,
          kind: :select,
          label: "Authentication",
          options: @auth_kinds,
          group: "Verification"
        },
        %{
          name: :secret_name,
          kind: :select,
          label: "Credential",
          group: "Verification",
          options: :webhook_secrets,
          help: "A verified signing credential saved by Ryker. Its value is never shown again."
        },
        %{
          name: :destination_transport,
          kind: :select,
          label: "Destination",
          options: @transports,
          group: "Send work to"
        },
        %{
          name: :destination_conversation_ref,
          kind: :text,
          label: "Conversation",
          group: "Send work to"
        },
        %{name: :destination_thread_ref, kind: :text, label: "Thread", group: "Send work to"},
        %{
          name: :context_ref,
          kind: :select,
          label: "Repository context",
          options: :scopes,
          group: "Send work to"
        },
        %{
          name: :group_by_labels,
          kind: :list,
          label: "Correlate by labels",
          group: "Send work to",
          help: "Events sharing these label values are treated as the same ongoing situation."
        },
        %{
          name: :mapping,
          kind: :mapping,
          label: "Field mapping",
          group: "Custom JSON",
          help:
            "Dotted paths into the payload, for a custom shape only. Event ID, status and " <>
              "title are required: without them an event cannot be identified, resolved or read."
        },
        %{
          name: :publication_lifecycle,
          kind: :lifecycle,
          label: "Deployment filters",
          help:
            "Optional. Restricts which deployment or Terraform events this source may report, " <>
              "to repositories that already have reviewed policies."
        }
      ]
    },
    %{
      key: :work,
      domain: :work,
      kind: :singleton,
      schema: Work,
      title: "Work placement",
      description:
        "Choose a separately managed worker workspace. The bundled worker does not need changes here.",
      fields: [
        %{
          name: :workspace_ref,
          kind: :select,
          label: "Worker workspace",
          options: :workspaces
        }
      ]
    },
    %{
      key: :retention,
      domain: :retention,
      kind: :retention,
      title: "Retention",
      description:
        "How long this installation keeps each kind of data. Horizons must stay ordered: " <>
          "operational data cannot outlive closed work, which cannot outlive episode history, " <>
          "which cannot outlive the audit trail. Global facts you confirmed are exempt.",
      fields: [
        %{
          name: :operational_data_seconds,
          kind: :days,
          label: "Prompts, replies and tool activity"
        },
        %{name: :conversation_memory_seconds, kind: :days, label: "Conversation memory"},
        %{name: :closed_work_seconds, kind: :days, label: "Closed work sessions"},
        %{name: :episode_history_seconds, kind: :days, label: "Episode history"},
        %{name: :audit_data_seconds, kind: :days, label: "Audit receipts"}
      ]
    },
    %{
      key: :pricing,
      domain: :pricing,
      kind: :collection,
      schema: PricingRate,
      item_key: :id,
      title: "Token rates",
      description:
        "Fallback USD estimates per million tokens. Ryker uses them only when the provider does not report cost.",
      fields: [
        %{name: :execution_target, kind: :text, label: "Execution target", group: "Model"},
        %{
          name: :input_usd_per_million,
          kind: :decimal,
          label: "Input",
          group: "USD per million tokens"
        },
        %{
          name: :cached_input_usd_per_million,
          kind: :decimal,
          label: "Cached input",
          group: "USD per million tokens"
        },
        %{
          name: :output_usd_per_million,
          kind: :decimal,
          label: "Output",
          group: "USD per million tokens"
        },
        %{
          name: :reasoning_usd_per_million,
          kind: :decimal,
          label: "Reasoning",
          group: "USD per million tokens"
        },
        %{name: :effective_from, kind: :date, label: "Effective from", group: "Source"},
        %{
          name: :provenance,
          kind: :text,
          label: "Where this rate came from",
          group: "Source"
        }
      ]
    }
  ]

  @spec sections() :: [map()]
  def sections, do: @sections

  @doc "Fields grouped for a readable form while preserving their declared order."
  def field_groups(section) do
    section.fields
    |> Enum.chunk_by(&Map.get(&1, :group))
    |> Enum.map(fn fields -> {Map.get(hd(fields), :group), fields} end)
  end

  @spec fetch(atom() | String.t()) :: {:ok, map()} | :error
  def fetch(key) when is_atom(key) do
    case Enum.find(@sections, &(&1.key == key)) do
      nil -> :error
      section -> {:ok, section}
    end
  end

  def fetch(key) when is_binary(key) do
    case Enum.find(@sections, &(Atom.to_string(&1.key) == key)) do
      nil -> :error
      section -> {:ok, section}
    end
  end

  @doc "Option pairs for a select, resolved against the current settings view."
  @spec options(map(), map()) :: [{String.t(), String.t()}]
  def options(%{options: :repositories}, view),
    do: Enum.map(view.snapshot.repositories, &{&1.ref, display_name(&1)})

  def options(%{options: :contexts}, view),
    do: Enum.map(view.snapshot.contexts, &{&1.ref, display_name(&1)})

  def options(%{options: :scopes}, view) do
    Enum.map(view.snapshot.repositories, &{&1.ref, "Repository " <> display_name(&1)}) ++
      Enum.map(view.snapshot.contexts, &{&1.ref, "Context " <> display_name(&1)})
  end

  def options(%{options: :advertised_policies}, view),
    do:
      Enum.map(
        view.workers.policies,
        &{&1.name, "#{&1.name} · #{String.slice(&1.digest, 0, 12)}"}
      )

  def options(%{options: :webhook_presets}, _view),
    do: Enum.map(Presets.all(), &{Atom.to_string(&1.adapter_kind), &1.title})

  def options(%{options: :webhook_secrets}, %{webhook_secret_names: names}) when is_list(names),
    do: Enum.map(names, &{&1, &1})

  def options(%{options: :webhook_secrets}, _view), do: []

  def options(%{options: :workspaces}, view),
    do:
      Enum.map(
        view.workers.workspaces,
        &{&1.ref, "#{&1.ref} · #{&1.eligible}/#{&1.workers} eligible"}
      )

  def options(%{options: options}, _view) when is_list(options), do: options

  @doc "The saved values of one section (or one collection row) as form strings."
  @spec draft(map(), map(), term()) :: %{String.t() => String.t()}
  def draft(section, view, item_key \\ nil)

  def draft(%{kind: :collection} = section, view, item_key) do
    case current_item(section, view, item_key) do
      nil -> Map.new(section.fields, &{field_name(&1), form_value(&1, nil)})
      item -> Map.new(section.fields, &{field_name(&1), form_value(&1, Map.get(item, &1.name))})
    end
  end

  def draft(section, view, _item_key) do
    current = Map.fetch!(view.snapshot, section.domain)
    Map.new(section.fields, &{field_name(&1), form_value(&1, Map.get(current, &1.name))})
  end

  @doc "The collection row being edited, or nil for a new one."
  @spec current_item(map(), map(), term()) :: struct() | nil
  def current_item(_section, _view, nil), do: nil

  def current_item(section, view, item_key) do
    Enum.find(items(section, view), &(to_string(Map.get(&1, section.item_key)) == item_key))
  end

  @doc "The saved rows of a collection section."
  @spec items(map(), map()) :: [struct()]
  def items(%{key: :pricing}, view), do: view.snapshot.pricing_rates
  def items(%{key: :repositories}, view), do: view.snapshot.repositories
  def items(%{key: :contexts}, view), do: view.snapshot.contexts
  def items(%{key: :github_bindings}, view), do: view.snapshot.github_bindings
  def items(%{key: :policies}, view), do: view.snapshot.policy_bindings
  def items(%{key: :webhooks}, view), do: view.snapshot.webhook_sources
  def items(_section, _view), do: []

  @doc """
  The draft a submitted form describes, with every control's own empty value.

  A value whose shape does not fit its control is discarded rather than kept:
  the browser is not the only thing that can send this event, and a draft that
  holds a map where a string belongs cannot even be rendered back.
  """
  @spec submitted(map(), map()) :: map()
  def submitted(section, params) do
    Map.new(section.fields, fn field ->
      {field_name(field), submitted_value(field, Map.get(params, field_name(field)))}
    end)
  end

  defp submitted_value(%{kind: kind} = field, value) when kind in [:mapping, :lifecycle] do
    if is_map(value),
      do: Map.new(subfields(field), &{&1, text(Map.get(value, &1))}),
      else: empty_value(field)
  end

  defp submitted_value(_field, value) when is_binary(value), do: value
  defp submitted_value(field, _mismatched), do: empty_value(field)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp empty_value(field), do: form_value(field, nil)

  @doc """
  Turns one submitted form into typed attributes for the settings write path.

  Unknown parameters are refused rather than ignored: a control that is not in
  the catalog has no business writing a setting.
  """
  @spec cast(map(), map()) :: {:ok, map()} | {:error, {:invalid_settings, [{atom(), atom()}]}}
  def cast(section, params) when is_map(params) do
    names = Map.new(section.fields, &{field_name(&1), &1})
    submitted = Map.take(params, Map.keys(names))

    Enum.reduce_while(section.fields, {:ok, %{}}, fn field, {:ok, attributes} ->
      case cast_field(field, Map.get(submitted, field_name(field), "")) do
        :skip -> {:cont, {:ok, attributes}}
        {:ok, value} -> {:cont, {:ok, Map.put(attributes, field.name, value)}}
        :error -> {:halt, {:error, {:invalid_settings, [{field.name, kind_error(field.kind)}]}}}
      end
    end)
  end

  # Evidence is displayed, never submitted: a pinned digest is not an input.
  defp cast_field(%{kind: :evidence}, _value), do: :skip

  defp cast_field(%{kind: :mapping} = field, value) when is_map(value) do
    mapping =
      field
      |> subfields()
      |> Enum.flat_map(fn name ->
        case String.trim(Map.get(value, name, "")) do
          "" -> []
          path -> [{name, path}]
        end
      end)
      |> Map.new()

    {:ok, if(mapping == %{}, do: nil, else: mapping)}
  end

  defp cast_field(%{kind: :mapping}, _absent), do: {:ok, nil}

  defp cast_field(%{kind: :lifecycle} = field, value) when is_map(value) do
    scope =
      Map.new(subfields(field), fn name ->
        {name, Map.get(value, name, "") |> String.split([",", " "], trim: true)}
      end)

    {:ok, if(Enum.all?(Map.values(scope), &(&1 == [])), do: nil, else: scope)}
  end

  defp cast_field(%{kind: :lifecycle}, _absent), do: {:ok, nil}

  defp cast_field(%{kind: :boolean}, value), do: {:ok, value in ["true", "on", true]}

  defp cast_field(%{kind: :select, blank: blank}, ""), do: {:ok, blank}

  defp cast_field(%{kind: :list}, value) when is_binary(value) do
    {:ok, value |> String.split([",", " ", "\n", "\t"], trim: true) |> Enum.map(&String.trim/1)}
  end

  defp cast_field(%{kind: kind}, "") when kind in [:text, :select], do: {:ok, nil}

  defp cast_field(%{kind: kind}, value) when kind in [:text, :select] and is_binary(value),
    do: {:ok, value}

  defp cast_field(%{kind: kind}, "") when kind in [:integer, :days, :decimal, :date],
    do: {:ok, nil}

  defp cast_field(%{kind: :integer}, value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :days}, value) when is_binary(value) do
    case Integer.parse(value) do
      {days, ""} when days > 0 -> {:ok, days * @day}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :decimal}, value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :date}, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :time}, value) when is_binary(value) do
    case Time.from_iso8601(pad_seconds(value)) do
      {:ok, time} -> {:ok, time}
      _invalid -> :error
    end
  end

  defp cast_field(_field, _mismatched), do: :error

  defp pad_seconds(value) do
    if String.length(value) == 5, do: value <> ":00", else: value
  end

  defp kind_error(:days), do: :days
  defp kind_error(:integer), do: :integer
  defp kind_error(:decimal), do: :decimal
  defp kind_error(:date), do: :date
  defp kind_error(:time), do: :time
  defp kind_error(_kind), do: :invalid

  @doc "The form name of a field."
  @spec field_name(map()) :: String.t()
  def field_name(%{name: name}), do: Atom.to_string(name)

  @doc "The fields of a composite control."
  @spec subfields(map()) :: [String.t()]
  def subfields(%{kind: :mapping}), do: @mapping_fields
  def subfields(%{kind: :lifecycle}), do: @lifecycle_fields

  @doc "One saved value as a table cell."
  @spec row_value(map(), term()) :: String.t()
  def row_value(%{kind: :mapping}, nil), do: "preset shape"
  def row_value(%{kind: :mapping}, mapping), do: "#{map_size(mapping)} fields mapped"
  def row_value(%{kind: :lifecycle}, nil), do: "no filter"

  def row_value(%{kind: :lifecycle}, scope),
    do: @lifecycle_fields |> Enum.map_join(" · ", &Enum.join(Map.get(scope, &1, []), ","))

  def row_value(field, value), do: form_value(field, value)

  @doc "A saved value rendered for its control."
  @spec form_value(map(), term()) :: String.t() | map()
  def form_value(%{kind: :mapping} = field, value),
    do: Map.new(subfields(field), &{&1, Map.get(value || %{}, &1, "")})

  def form_value(%{kind: :lifecycle} = field, value),
    do: Map.new(subfields(field), &{&1, Enum.join(Map.get(value || %{}, &1, []), ", ")})

  def form_value(_field, nil), do: ""
  def form_value(%{kind: :boolean}, value), do: to_string(value)
  def form_value(%{kind: :list}, values), do: Enum.join(values, ", ")
  def form_value(%{kind: :days}, seconds), do: Integer.to_string(div(seconds, @day))

  def form_value(%{kind: :time}, %Time{} = time),
    do: time |> Time.truncate(:second) |> to_string()

  def form_value(%{kind: :decimal}, %Decimal{} = value), do: Decimal.to_string(value, :normal)
  def form_value(_field, value), do: to_string(value)

  defp display_name(%{ref: ref, display_name: nil}), do: ref
  defp display_name(%{ref: ref, display_name: name}), do: "#{name} (#{ref})"
end
