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

  alias Ryker.ControlPlane.Environments
  alias Ryker.Settings.Environment
  alias Ryker.Slack.Names
  alias Ryker.Webhooks.Presets
  alias Ryker.Work.ExecutionTarget

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
  # How a sender proves a request is theirs, each said the way it works for
  # them. A signed request's secret must be at least 32 characters: the
  # webhook listener refuses a shorter one, and the credential form now
  # insists on it (QA, 2026-09-25).
  @auth_kinds [
    {"hmac_sha256", "They sign each request",
     "The sender signs every request with the signing credential, so Ryker knows it came " <>
       "from them unchanged. The credential must be at least 32 characters."},
    {"bearer", "They send a token",
     "The sender puts the signing credential in each request's Authorization header, as " <>
       "Grafana does. Anyone who sees a request could send one too."}
  ]
  @transports [
    {"slack", "A Slack channel"},
    {"github", "A GitHub issue or pull request"},
    {"control_plane", "A Chat conversation"}
  ]
  @mapping_fields ~w(event_id status title severity summary source_url starts_at ends_at incident_id item_id labels annotations revision)
  @lifecycle_fields ~w(environments kinds repositories targets)
  # A subfield's label, and for the deployment reports what goes in it.
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
    "environments" => "Deploy environments, such as production",
    "kinds" => "What it reports: deployment, terraform or both",
    "repositories" => "Ryker's names for the repositories",
    "targets" => "The services or stacks it deploys"
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
          help: "Lowercase letters, numbers, dashes and underscores, such as inc.",
          errors: %{
            required: "Choose how incident room names start, such as inc.",
            format: "Use 1 to 20 lowercase letters, numbers, dashes or underscores, such as inc."
          }
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
    # A policy is what a worker's session may do: the Coop policy the bundled
    # worker writes names the model (its target), whether the repository is
    # read-only, the repositories mounted beside it and what else the session
    # may reach. The page says that in those words.
    %{
      key: :policies,
      domain: :policies,
      kind: :collection,
      schema: PolicyBinding,
      item_key: :id,
      item_label: "policy",
      row_status: {Ryker.Settings.WorkerPolicies, :binding_status},
      title: "What each kind of work may do",
      description:
        "A policy is a worker's rulebook for one kind of work: which model runs it, whether " <>
          "it may change files, which repositories it sees and what it may run. " <>
          "The bundled worker writes these for you.",
      empty: {
        "No policies yet",
        "The bundled worker writes these for you. Add one only for a worker you run yourself."
      },
      fields: [
        %{
          name: :purpose,
          kind: :select,
          label: "Kind of work",
          options: @purposes,
          help:
            "Routing, learning, incident rooms and scheduled read-only or approved work apply " <>
              "everywhere, and conversation may too; the others apply to one repository or " <>
              "environment."
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
        # Work in an environment may change any of its repositories, so an
        # environment binds each kind of work once per repository.
        %{
          name: :repository_ref,
          kind: :select,
          label: "Repository in that environment",
          options: :repositories,
          blank: "",
          help: "Only for one environment: the repository its work is in. Leave empty otherwise."
        },
        %{
          name: :policy_name,
          kind: :select,
          label: "Worker policy",
          options: :advertised_policies,
          help: "Only policies a connected worker offers can be chosen."
        },
        %{name: :policy_digest, kind: :evidence, label: "Reviewed version"}
      ]
    },
    # Every field says what it is for in plain words and, when refused, what
    # to choose (QA, 2026-09-25). A new source starts on what this
    # installation has: its default environment, its only signing
    # credential, Grafana's shape, accepting events.
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
          help: "The end of this source's address. It cannot change later.",
          errors: %{
            required: "Name the source, such as grafana. Its address ends in this name.",
            format:
              "Start with a lowercase letter, then use lowercase letters, numbers, dashes and " <>
                "underscores, such as grafana."
          }
        },
        %{
          name: :enabled,
          kind: :boolean,
          label: "Accept events",
          group: "Source",
          default: "true",
          help: "Turn this off to stop taking events at this address without removing the source."
        },
        %{
          name: :adapter_kind,
          kind: :choice,
          label: "What the sender sends",
          group: "Source",
          options: :webhook_presets,
          default: "grafana",
          errors: %{required: "Choose what the sender sends."}
        },
        %{
          name: :auth_kind,
          kind: :choice,
          label: "How senders prove who they are",
          options: @auth_kinds,
          group: "Verification",
          default: "bearer",
          errors: %{required: "Choose how the sender proves a request is theirs."}
        },
        %{
          name: :secret_name,
          kind: :select,
          label: "Signing credential",
          group: "Verification",
          options: :webhook_secrets,
          required: true,
          default: :only_credential,
          prompt: "Choose a credential",
          help: "The shared secret the sender uses, from Signing credentials above.",
          errors: %{
            required:
              "Choose the signing credential this sender uses. Add one under Signing " <>
                "credentials above if there is none.",
            unregistered_secret:
              "That signing credential no longer exists. Choose another, or add one under " <>
                "Signing credentials above."
          }
        },
        %{
          name: :destination_transport,
          kind: :select,
          label: "Where Ryker posts about these events",
          options: @transports,
          group: "Where work goes",
          required: true,
          default: "slack",
          errors: %{required: "Choose where Ryker posts about these events."}
        },
        %{
          name: :destination_conversation_ref,
          kind: :text,
          label: "Conversation",
          group: "Where work goes",
          errors: %{
            required: "Choose where Ryker posts about these events.",
            length: "That is too long to be a conversation Ryker can post in."
          }
        },
        %{
          name: :destination_thread_ref,
          kind: :text,
          label: "Thread (optional)",
          group: "Where work goes",
          help:
            "Only to post every event into one existing thread. Leave empty and each " <>
              "situation gets its own message."
        },
        %{
          name: :environment_ref,
          kind: :select,
          label: "Environment",
          options: :environments,
          group: "Where work goes",
          required: true,
          default: :default_environment,
          prompt: "Choose an environment",
          help: "The repositories and Emisar account work from these events may use.",
          errors: %{
            required: "Choose the environment the work from these events runs in.",
            unknown_environment: "That environment no longer exists. Choose another."
          }
        },
        %{
          name: :group_by_labels,
          kind: :list,
          label: "Group by labels",
          group: "Where work goes",
          help:
            "Optional. Events with the same values for these labels, such as service and " <>
              "cluster, count as one ongoing situation."
        },
        %{
          name: :mapping,
          kind: :mapping,
          label: "Where each field is in the JSON",
          group: "Custom JSON",
          help:
            "Dotted paths into the payload, such as details.severity. Event ID, status and " <>
              "title are required: without them an event cannot be identified, resolved or read.",
          errors: %{
            mapping_required: "Fill in where the event ID, status and title are.",
            mapping_values: "Each path must be filled in and under 1,024 characters."
          }
        },
        %{
          name: :publication_lifecycle,
          kind: :lifecycle,
          label: "Deployment reports",
          help:
            "Lets this sender tell Ryker when a change Ryker opened was deployed or applied, " <>
              "so Ryker can check it. List exactly what it may report; anything else is " <>
              "ignored.",
          errors: %{
            lifecycle:
              "Fill in all four, name repositories Ryker has, and report deployment, " <>
                "terraform or both."
          }
        }
      ]
    },
    # Each `used` sentence says where the bundled worker runs that model, as
    # the code decides it: routing (`Ryker.Admission.Decision`) answers a
    # reply on the conversational class and new or continued work on the
    # standard or deep one; `Ryker.BundledCoop` writes each policy with the
    # model saved for its purpose; `Ryker.Runtime.Assembly` runs work with no
    # repository (an environment without any, or no environment) on the
    # installation's conversation policy for every class, a confirmed task on
    # the contributor, schedules on theirs, and a whole incident room on the
    # incident policy. Change a sentence only with the code it describes.
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
          used:
            "Runs first on every message and event Ryker picks up, from Slack, Chat, GitHub " <>
              "and webhooks. It decides whether to answer, start work, add it to earlier work " <>
              "or stay quiet, and picks Conversation, Standard or Deep work for it. It runs " <>
              "more often than anything else, so speed and price matter most here.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :conversation_model,
          kind: :select,
          label: "Conversation",
          group: "Routing and replies",
          used:
            "Writes the replies Ryker can give straight away, without a longer investigation: " <>
              "answers from what it already knows, quick questions and small lookups. Where " <>
              "there is no repository to work in, it does the standard and deep work too.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :standard_model,
          kind: :select,
          label: "Standard work",
          group: "Work",
          used:
            "Investigations that use tools: reading code, checking logs, running read-only " <>
              "commands and asking Emisar to run something. Routing picks it for most work " <>
              "that needs more than a quick answer.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :deep_model,
          kind: :select,
          label: "Deep work",
          group: "Work",
          used:
            "The same kind of work, when routing judges the request hard, ambiguous or risky.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :contributor_model,
          kind: :select,
          label: "Contributor work",
          group: "Work",
          used:
            "Tasks that change code, once a person confirms them. When pull requests are on, " <>
              "Ryker opens one for the change.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :schedule_model,
          kind: :select,
          label: "Scheduled work",
          group: "Other work",
          used:
            "Work that starts on its own when a schedule is due: the reminders and recurring " <>
              "checks people set up by asking Ryker.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :incident_model,
          kind: :select,
          label: "Incident rooms",
          group: "Other work",
          used:
            "Everything Ryker does in an incident room, the Slack channel it opens for an " <>
              "incident: the investigation and every reply there. It also runs an incident " <>
              "investigated in its own thread instead of a room.",
          options: :bundled_models,
          required: true
        },
        %{
          name: :learning_model,
          kind: :select,
          label: "Learning",
          group: "Other work",
          used:
            "Reads the messages Ryker picks up in the background, including ones it did not " <>
              "answer, and notes what is worth remembering about each conversation. It never " <>
              "replies, and runs only while learning is on.",
          options: :bundled_models,
          required: true
        }
      ]
    },
    # A worker enrols under a workspace name and reports it on every sync;
    # people know it as the install the worker belongs to.
    %{
      key: :work,
      domain: :work,
      kind: :singleton,
      schema: Work,
      title: "Where work runs",
      description: "Only for workers you run yourself. The bundled worker needs no change here.",
      fields: [
        %{
          name: :workspace_ref,
          kind: :select,
          label: "Worker install",
          options: :workspaces,
          help:
            "Which worker install runs Ryker's work. " <>
              "A worker reports its install name when it connects."
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
          help: "The provider and model, joined by a colon.",
          errors: %{
            format: "Write the provider and model joined by a colon, like codex:gpt-5.6-sol."
          }
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
          group: "US dollars per million tokens",
          help: "Leave empty when output already counts reasoning, as Codex and Claude report it."
        },
        %{
          name: :effective_from,
          kind: :date,
          label: "Effective from",
          group: "Source",
          help: "Used for usage on and after this day.",
          errors: %{
            required: "Choose the first day this price applies.",
            already_bound: {__MODULE__, :price_taken}
          }
        },
        %{
          name: :provenance,
          kind: :text,
          label: "Where this price came from",
          group: "Source",
          help:
            "A link to the provider's price list, or a note on where these numbers came from.",
          errors: %{
            required:
              "Add where this price came from, such as a link to the provider's price list."
          }
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
    do: Enum.map(Environments.ordered(view.snapshot.environments), &{&1.ref, &1.display_name})

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
    do: Enum.map(Presets.all(), &{Atom.to_string(&1.adapter_kind), &1.title, &1.description})

  def options(%{options: :slack_channels}, view) do
    for %{workspace_ref: workspace, channel_ref: channel} <- view.slack_channels,
        do: {"slack:#{workspace}:#{channel}", Names.name(workspace, channel)}
  end

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
  # the model and its effort. Every select lists them in one order, by model
  # and then effort, and marks the saved one: QA, 2026-09-25, found each
  # select putting its own saved model first, eight orders for one list.
  def options(%{options: :bundled_models, name: name}, view) do
    current = Map.fetch!(view.snapshot.work, name)
    profile = (ExecutionTarget.parts(current) || %{})[:profile] || "default"

    priced =
      for %{execution_target: "codex:" <> _ = model} <- view.snapshot.pricing_rates,
          effort <- @efforts,
          uniq: true,
          do: "#{model}/#{effort}@#{profile}"

    [current | priced]
    |> Enum.uniq()
    |> Enum.sort_by(&model_order/1)
    |> Enum.map(&{&1, model_label(&1) <> if(&1 == current, do: " (current)", else: "")})
  end

  def options(%{options: options}, _view) when is_list(options), do: options

  defp model_order(target) do
    case ExecutionTarget.parts(target) do
      %{model: model, effort: effort} ->
        {model, Enum.find_index(@efforts, &(&1 == effort)) || length(@efforts), target}

      nil ->
        {target, 0, target}
    end
  end

  defp workers(1), do: "worker"
  defp workers(_count), do: "workers"

  @doc """
  What a second price for the same model and day says: which price is
  already there, and the two ways out.
  """
  @spec price_taken(%{String.t() => String.t()}) :: String.t()
  def price_taken(draft) do
    target = Map.get(draft, "execution_target", "")
    model = (ExecutionTarget.parts(target) || %{model: target}).model

    day =
      case Date.from_iso8601(Map.get(draft, "effective_from", "")) do
        {:ok, date} -> Calendar.strftime(date, "%-d %b %Y")
        {:error, _invalid} -> "that day"
      end

    "#{model} already has a price from #{day}. Choose another day, or edit that price."
  end

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
      nil -> Map.new(section.fields, &{field_name(&1), default(&1, view)})
      item -> Map.new(section.fields, &{field_name(&1), form_value(&1, Map.get(item, &1.name))})
    end
  end

  def draft(section, view, _item_key) do
    current = Map.fetch!(view.snapshot, section.domain)
    Map.new(section.fields, &{field_name(&1), form_value(&1, Map.get(current, &1.name))})
  end

  # What a new row starts with: the field's own default, or the one thing
  # this installation has to choose, such as its default environment or its
  # only signing credential.
  defp default(%{default: :default_environment} = field, view) do
    case {Environment.default(view.snapshot), view.snapshot.environments} do
      {%{ref: ref}, _environments} -> ref
      {nil, [%{ref: ref}]} -> ref
      {nil, _none_or_several} -> form_value(field, nil)
    end
  end

  defp default(%{default: :only_credential} = field, view) do
    case options(field, view) do
      [{name, _label}] -> name
      _none_or_several -> form_value(field, nil)
    end
  end

  defp default(%{default: value}, _view) when is_binary(value), do: value
  defp default(field, _view), do: form_value(field, nil)

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
