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
    Slack,
    WebhookSource,
    Work
  }

  alias Ryker.ControlPlane.ExecutionTarget
  alias Ryker.Webhooks.Presets

  @day 86_400
  @longest_days 3_650
  @efforts ~w(low medium high xhigh)
  # The words a person picks between, each with what Ryker will then do.
  @participation [
    {"mentions", "Only when mentioned", "Ryker replies when someone writes @Ryker."},
    {"proactive", "Join relevant conversations", "Ryker also replies when it can clearly help."},
    {"shadow", "Watch quietly", "Ryker reads and learns, but never replies."}
  ]
  @purposes [
    {"admission", "Routing incoming messages"},
    {"learning", "Learning"},
    {"incident", "Incident rooms"},
    {"schedule_read_only", "Scheduled read-only work"},
    {"schedule_governed", "Scheduled approved operations"},
    {"conversational", "Conversation"},
    {"standard", "Standard work"},
    {"deep", "Deep work"},
    {"contributor", "Contributor work"},
    {"schedule", "Scheduled work"}
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
  @subfield_labels %{
    "event_id" => "Event ID",
    "status" => "Status",
    "title" => "Title",
    "severity" => "Severity",
    "summary" => "Summary",
    "source_url" => "Link",
    "starts_at" => "Started at",
    "ends_at" => "Ended at",
    "incident_id" => "Incident ID",
    "item_id" => "Item ID",
    "labels" => "Labels",
    "annotations" => "Annotations",
    "revision" => "Revision",
    "environments" => "Environments",
    "kinds" => "Kinds",
    "repositories" => "Repositories",
    "targets" => "Targets"
  }
  @scope_kinds [
    {"installation", "Everywhere"},
    {"repository", "One repository"},
    {"environment", "One environment"}
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
    # Whether Slack is on at all is the connection itself (Connect and
    # Disconnect on the Slack page), not a checkbox in this form.
    %{
      key: :slack,
      domain: :slack,
      kind: :singleton,
      schema: Slack,
      title: "Slack",
      description: "How Ryker takes part in channels and the rooms it opens for incidents.",
      groups: %{
        "New channels" => %{
          id: "new-channels",
          lede:
            "Used in every channel that has not made its own choice. " <>
              "You can change each channel on its own page."
        },
        "Incident rooms" => %{lede: "Channels Ryker creates for an incident."}
      },
      fields: [
        %{
          name: :default_participation,
          kind: :choice,
          label: "When to reply",
          options: @participation,
          group: "New channels"
        },
        %{
          name: :channel_prefix,
          kind: :text,
          label: "Name starts with",
          group: "Incident rooms",
          help: "Lowercase letters, numbers, dashes and underscores."
        },
        %{
          name: :incident_private,
          kind: :boolean,
          label: "Make incident rooms private",
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
      title: "Pull requests",
      description:
        "Whether Ryker opens pull requests for code it changes, and how they are signed.",
      fields: [
        %{
          name: :enabled,
          kind: :boolean,
          label: "Let Ryker open pull requests",
          help: "Ryker pushes a branch and opens a pull request when its work changes code."
        },
        %{
          name: :branch_prefix,
          kind: :text,
          label: "Branch names start with",
          help: "Branches that already exist keep their names."
        },
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
        %{name: :ryker_actor_id, kind: :integer, label: "Ryker actor ID"}
      ]
    },
    %{
      key: :policies,
      domain: :policies,
      kind: :collection,
      schema: PolicyBinding,
      item_key: :id,
      item_label: "execution policy",
      row_status: {Ryker.Settings.WorkerPolicies, :binding_status},
      title: "Execution policies",
      description:
        "Which reviewed worker policy runs each kind of work. " <>
          "The bundled worker supplies these for you.",
      empty: {
        "No execution policies",
        "The bundled worker supplies these automatically. Add one only for a separately managed worker fleet."
      },
      fields: [
        %{
          name: :purpose,
          kind: :select,
          label: "Kind of work",
          options: @purposes,
          help:
            "Routing, learning, incident rooms and scheduled read-only or approved work apply " <>
              "everywhere; the others apply to one repository or environment."
        },
        %{name: :scope_kind, kind: :select, label: "Applies to", options: @scope_kinds},
        %{
          name: :scope_ref,
          kind: :select,
          label: "Repository or environment",
          options: :scopes,
          blank: "",
          help: "Leave empty when the policy applies everywhere."
        },
        %{
          name: :policy_name,
          kind: :select,
          label: "Worker policy",
          options: :advertised_policies,
          help: "Only policies a connected worker offers can be chosen."
        },
        %{name: :policy_digest, kind: :evidence, label: "Pinned version"}
      ]
    },
    %{
      key: :webhooks,
      domain: :webhooks,
      kind: :collection,
      schema: WebhookSource,
      item_key: :name,
      item_label: "webhook source",
      title: "Webhook sources",
      description:
        "Each source is one sender, such as a Grafana contact point, with its own address.",
      empty: {
        "No webhook sources yet",
        "Add a source for each system that should send events to Ryker."
      },
      fields: [
        %{
          name: :name,
          kind: :text,
          label: "Source name",
          identity: true,
          group: "Source",
          help: "The end of this source's address. It cannot change later."
        },
        %{name: :enabled, kind: :boolean, label: "Accept events", group: "Source"},
        %{
          name: :adapter_kind,
          kind: :select,
          label: "Payload shape",
          group: "Source",
          options: :webhook_presets,
          help: "A preset reads the sender's own format. It never chooses where work goes."
        },
        %{
          name: :auth_kind,
          kind: :select,
          label: "How senders prove who they are",
          options: @auth_kinds,
          group: "Verification"
        },
        %{
          name: :secret_name,
          kind: :select,
          label: "Signing credential",
          group: "Verification",
          options: :webhook_secrets,
          help: "One of the credentials above. Its secret is never shown again."
        },
        %{
          name: :destination_transport,
          kind: :select,
          label: "Send work to",
          options: @transports,
          group: "Where work goes"
        },
        %{
          name: :destination_conversation_ref,
          kind: :text,
          label: "Conversation",
          group: "Where work goes",
          placeholder: "slack:T0123456789:C0123456789",
          help: "For Slack: slack, the workspace ID and the channel ID, joined by colons."
        },
        %{
          name: :destination_thread_ref,
          kind: :text,
          label: "Thread (optional)",
          group: "Where work goes"
        },
        %{
          name: :environment_ref,
          kind: :select,
          label: "Environment",
          options: :environments,
          group: "Where work goes",
          help: "Work from this source runs in this environment."
        },
        %{
          name: :group_by_labels,
          kind: :list,
          label: "Group by labels",
          group: "Where work goes",
          help: "Events with the same values for these labels count as one ongoing situation."
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
            "Optional. Limits which deployment or Terraform events this source may report, " <>
              "to repositories that already have reviewed policies."
        }
      ]
    },
    %{
      key: :model,
      domain: :work,
      kind: :singleton,
      schema: Work,
      title: "Models",
      description:
        "The model and reasoning effort for each kind of work. " <>
          "A saved change reaches new work within seconds.",
      fields: [
        %{
          name: :routing_model,
          kind: :select,
          label: "Routing",
          group: "Routing and replies",
          help: "Decides how Ryker handles each incoming message.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :conversation_model,
          kind: :select,
          label: "Conversation",
          group: "Routing and replies",
          help: "Replies to questions and chat.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :standard_model,
          kind: :select,
          label: "Standard work",
          group: "Work",
          help: "Investigations and tool-backed work.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :deep_model,
          kind: :select,
          label: "Deep work",
          group: "Work",
          help: "Harder, ambiguous or high-stakes work.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :contributor_model,
          kind: :select,
          label: "Contributor work",
          group: "Work",
          help: "Work that writes to a repository.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :schedule_model,
          kind: :select,
          label: "Scheduled work",
          group: "Other work",
          help: "Runs started by a schedule.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :incident_model,
          kind: :select,
          label: "Incident rooms",
          group: "Other work",
          help: "Work in incident rooms.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :learning_model,
          kind: :select,
          label: "Learning",
          group: "Other work",
          help: "Background learning from conversations.",
          options: :bundled_models,
          required: true
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
        "Only for a separately managed worker fleet. The bundled worker needs no changes here.",
      fields: [
        %{
          name: :workspace_ref,
          kind: :select,
          label: "Worker workspace",
          options: :workspaces,
          help: "The workspace whose workers run Ryker's work."
        }
      ]
    },
    # Listed in the order the limits must keep: each of the first four at
    # least as long as the one above it. Conversation memory only has to
    # outlast the first.
    %{
      key: :retention,
      domain: :retention,
      kind: :retention,
      title: "Data retention",
      description: "How many days Ryker keeps each kind of data before deleting it.",
      help:
        "Each limit must be at least as long as the one above it, and conversation memory at " <>
          "least as long as prompts, replies and tool activity. Facts you confirmed are kept regardless.",
      fields: [
        %{
          name: :operational_data_seconds,
          kind: :days,
          label: "Prompts, replies and tool activity",
          help: "The full text of messages Ryker received and of each model and tool call."
        },
        %{
          name: :closed_work_seconds,
          kind: :days,
          label: "Finished work",
          help: "Closed incident rooms, task cards and finished work sessions."
        },
        %{
          name: :episode_history_seconds,
          kind: :days,
          label: "Request history",
          help: "The step-by-step record of each finished request."
        },
        %{
          name: :audit_data_seconds,
          kind: :days,
          label: "Audit trail",
          help: "Records of changes to settings, instructions and channels."
        },
        %{
          name: :conversation_memory_seconds,
          kind: :days,
          label: "Conversation memory",
          help: "What Ryker remembers about each conversation."
        }
      ]
    },
    %{
      key: :pricing,
      domain: :pricing,
      kind: :collection,
      schema: PricingRate,
      item_key: :id,
      item_label: "price",
      title: "Prices",
      description: "Ryker uses these to estimate cost when the provider does not report it.",
      empty: {"No prices yet", "Add a price so Ryker can estimate what each model costs."},
      fields: [
        %{
          name: :execution_target,
          kind: :text,
          label: "Model",
          placeholder: "codex:gpt-5.6-sol",
          help: "The provider and model, joined by a colon."
        },
        %{
          name: :input_usd_per_million,
          kind: :decimal,
          label: "Input",
          group: "US dollars per million tokens"
        },
        %{
          name: :cached_input_usd_per_million,
          kind: :decimal,
          label: "Cached input",
          group: "US dollars per million tokens"
        },
        %{
          name: :output_usd_per_million,
          kind: :decimal,
          label: "Output",
          group: "US dollars per million tokens"
        },
        %{
          name: :reasoning_usd_per_million,
          kind: :decimal,
          label: "Reasoning",
          group: "US dollars per million tokens"
        },
        %{
          name: :effective_from,
          kind: :date,
          label: "Effective from",
          group: "Source",
          help: "Used for usage on and after this day."
        },
        %{
          name: :provenance,
          kind: :text,
          label: "Where this price came from",
          group: "Source",
          placeholder: "Provider price list"
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

  @doc """
  What a group of fields says about itself when the form is a page of its
  own sections: an optional anchor other pages link to and one sentence.
  """
  @spec group_details(map(), String.t() | nil) :: map()
  def group_details(section, group), do: Map.get(Map.get(section, :groups, %{}), group, %{})

  @doc "The words a composite control shows for one of its parts."
  @spec subfield_label(String.t()) :: String.t()
  def subfield_label(subfield), do: Map.get(@subfield_labels, subfield, subfield)

  @doc "The longest limit, in days, any kind of data can be kept."
  def longest_days, do: @longest_days

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

  def options(%{options: :environments}, view),
    do: Enum.map(view.snapshot.environments, &{&1.ref, &1.display_name})

  def options(%{options: :scopes}, view) do
    Enum.map(view.snapshot.repositories, &{&1.ref, "Repository " <> display_name(&1)}) ++
      Enum.map(view.snapshot.environments, &{&1.ref, "Environment " <> &1.display_name})
  end

  # A policy is chosen by name; its pinned version is copied from the worker
  # that offers it. Two versions of one name are an ambiguity the write path
  # refuses, so the option says so instead of showing digests.
  def options(%{options: :advertised_policies}, view) do
    view.workers.policies
    |> Enum.group_by(& &1.name)
    |> Enum.sort_by(fn {name, _advertisements} -> name end)
    |> Enum.map(fn
      {name, [_one]} -> {name, name}
      {name, _several} -> {name, name <> " · workers offer different versions"}
    end)
  end

  def options(%{options: :webhook_presets}, _view),
    do: Enum.map(Presets.all(), &{Atom.to_string(&1.adapter_kind), &1.title})

  def options(%{options: :webhook_secrets}, %{webhook_secret_names: names}) when is_list(names),
    do: Enum.map(names, &{&1, &1})

  def options(%{options: :webhook_secrets}, _view), do: []

  def options(%{options: :workspaces}, view),
    do:
      Enum.map(
        view.workers.workspaces,
        &{&1.ref, "#{&1.ref} · #{&1.eligible} of #{&1.workers} #{workers(&1.workers)} ready"}
      )

  # Every priced Codex model at each effort the bundled worker can run, on the
  # saved model's profile. A saved model outside that list stays selectable.
  # Every option runs through Codex on the same profile, so a label names only
  # the model and its effort.
  def options(%{options: :bundled_models, name: name}, view) do
    current = Map.fetch!(view.snapshot.work, name)
    profile = (ExecutionTarget.parts(current) || %{})[:profile] || "default"

    priced =
      for %{execution_target: "codex:" <> _ = model} <- view.snapshot.pricing_rates,
          effort <- @efforts,
          uniq: true,
          do: "#{model}/#{effort}@#{profile}"

    Enum.map(Enum.uniq([current | priced]), &{&1, model_label(&1)})
  end

  def options(%{options: options}, _view) when is_list(options), do: options

  defp workers(1), do: "worker"
  defp workers(_count), do: "workers"

  @doc "The words for a saved model, as its option in the select reads."
  @spec model_label(String.t()) :: String.t()
  def model_label(target) do
    case ExecutionTarget.present(target) do
      %{model: model, meta: meta} when is_binary(meta) ->
        model <> " · " <> (meta |> String.split(" · ") |> hd())

      %{compact: compact} ->
        compact
    end
  end

  @doc "Whether a token rate prices this model, so its cost can be estimated."
  @spec priced?(String.t(), map()) :: boolean()
  def priced?(target, view) do
    case ExecutionTarget.parts(target) do
      %{provider: provider, model: model} ->
        Enum.any?(view.snapshot.pricing_rates, &(&1.execution_target == "#{provider}:#{model}"))

      nil ->
        false
    end
  end

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

  defp cast_field(%{kind: kind}, "") when kind in [:text, :select, :choice], do: {:ok, nil}

  defp cast_field(%{kind: kind}, value)
       when kind in [:text, :select, :choice] and is_binary(value),
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

  # A fixed choice reads as the words the form offered, not the stored value.
  def row_value(%{kind: kind, options: options} = field, value)
      when kind in [:select, :choice] and is_list(options) do
    stored = form_value(field, value)

    case Enum.find(options, &(elem(&1, 0) == stored)) do
      nil -> stored
      option -> elem(option, 1)
    end
  end

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

  defp display_name(%{ref: ref, display_name: name}) when name in [nil, ""], do: ref
  defp display_name(%{display_name: name}), do: name
end
