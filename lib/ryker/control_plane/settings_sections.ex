defmodule Ryker.ControlPlane.SettingsSections do
  @moduledoc """
  The editable product settings as data: which sections exist, which typed
  fields each one writes, and how a submitted form becomes typed attributes.

  The catalog is deliberately explicit. A generic settings bag would let a form
  write a column nobody reviewed; here every control names a field that the
  settings changeset already validates, and anything the form cannot type
  (a worker identity or a credential value) is not here.
  """
  alias Ryker.ControlPlane.Environments
  alias Ryker.ConversationRef
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.Webhooks
  alias Ryker.Wording
  alias Ryker.Work

  @day 86_400
  @longest_days 3_650
  # What a refused list of models says, whichever kind of work it is for.
  @ladder_errors %{
    length: "Keep one model and at most three fallbacks.",
    cast: "Choose a model, a reasoning effort and an account for each one.",
    format: "Choose a model, a reasoning effort and an account for each one.",
    duplicate: "The same model, effort and account is listed twice. Change one or remove it.",
    unknown_account:
      "Choose an account listed under Model accounts. To use another account, sign it in " <>
        "on the worker, then add it there.",
    unpriced: "Choose a model that has a price under Model prices.",
    shared_accounts:
      "A request can move between Conversation, Standard and Deep work, so these three must " <>
        "use the same accounts, in the same order. Their models and efforts can differ."
  }
  # One model and its fallbacks as the form holds them: each part of a model.
  @ladder_parts ~w(model effort account)
  # How many entries a submitted list may carry before the rest are ignored;
  # more than a list takes, four models or sixteen accounts, is refused with a
  # reason, not cut short.
  @list_bound 32
  # The words a person picks between, each with what Ryker will then do.
  @participation [
    {"mentions", "Only when mentioned", "Ryker replies when someone writes @Ryker."},
    {"proactive", "Join relevant conversations", "Ryker also replies when it can clearly help."},
    {"shadow", "Watch quietly", "Ryker reads and learns without replying."}
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
  @mapping_fields Enum.map(Webhooks.Route.mapping_fields(), &Atom.to_string/1)
  @lifecycle_fields Enum.map(Webhooks.Route.lifecycle_fields(), &Atom.to_string/1)
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
  # What each subfield's value looks like, shown in the empty box: a dotted
  # path into the payload, or a comma-separated list (Andrew, 2026-09-27: "for
  # inputs where format is known we should show placeholder showing it").
  @subfield_placeholders %{
    "event_id" => "event.id",
    "status" => "event.status",
    "title" => "event.title",
    "severity" => "event.severity",
    "summary" => "event.summary",
    "source_url" => "event.url",
    "starts_at" => "event.started_at",
    "ends_at" => "event.ended_at",
    "incident_id" => "incident.id",
    "item_id" => "item.id",
    "labels" => "event.labels",
    "annotations" => "event.annotations",
    "revision" => "deploy.revision",
    "environments" => "production, staging",
    "kinds" => "deployment, terraform",
    "repositories" => "acme-api, acme-web",
    "targets" => "checkout, payments"
  }
  # What the local routing model does in each mode, in the words a person
  # picks between.
  @local_routing_modes [
    {"off", "Off",
     "Routing uses only the provider model, and nothing is sent to the local model."},
    {"shadow", "Compare in the background",
     "After the provider model has decided, the local model is asked the same routing prompt. " <>
       "Its page, See how it compares, shows how often it would have decided the same. Routing " <>
       "still uses only the provider model's decision."}
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
    # Disconnect on the Slack page), not a checkbox in these forms. New
    # channels and incident rooms are separate cards on that page, each with
    # its own Save (Andrew, 2026-09-26: each part of a long page is a card
    # with its controls and its actions). The Channels page links to the
    # first by its anchor.
    %{
      key: :new_channels,
      domain: :slack,
      kind: :singleton,
      schema: Settings.Slack,
      anchor: "new-channels",
      title: "New channels",
      description:
        "Used in every channel that has not made its own choice. " <>
          "You can change each channel on its own page.",
      fields: [
        %{
          name: :default_participation,
          kind: :choice,
          label: "When to reply",
          options: @participation
        }
      ]
    },
    %{
      key: :incident_rooms,
      domain: :slack,
      kind: :singleton,
      schema: Settings.Slack,
      title: "Incident rooms",
      description: "Channels Ryker creates for an incident.",
      fields: [
        %{
          name: :channel_prefix,
          kind: :text,
          label: "Name starts with",
          placeholder: "inc",
          help: "Lowercase letters, numbers, dashes and underscores, such as inc.",
          errors: %{
            required: "Choose how incident room names start, such as inc.",
            format: "Use 1 to 20 lowercase letters, numbers, dashes or underscores, such as inc."
          }
        },
        %{name: :incident_private, kind: :boolean, label: "Make incident rooms private"}
      ]
    },
    # Shown under "Who can manage Ryker" on the Slack page, beside the people
    # chosen there by name (Andrew, 2026-09-26: admins can by default, with a
    # switch to turn that off).
    %{
      key: :slack_admins,
      domain: :slack,
      kind: :singleton,
      schema: Settings.Slack,
      title: "Workspace admins and owners",
      description: "Whether the workspace's admins and owners can manage Ryker.",
      fields: [
        %{
          name: :workspace_admins_manage,
          kind: :boolean,
          label: "Workspace admins and owners can manage Ryker",
          help:
            "Anyone Slack lists as an admin or owner of the workspace, as well as the " <>
              "people chosen here."
        }
      ]
    },
    %{
      key: :publication,
      domain: :publication,
      kind: :singleton,
      schema: Settings.Publication,
      title: "Pull requests",
      description:
        "Whether Ryker opens pull requests for code it changes, and how they are signed.",
      fields: [
        %{
          name: :enabled,
          kind: :boolean,
          label: "Let Ryker open pull requests",
          help: "Ryker pushes a branch and opens a pull request when its work changes code.",
          errors: %{github_required: "Connect the GitHub App first."}
        },
        %{
          name: :branch_prefix,
          kind: :text,
          label: "Branch names start with",
          placeholder: "ryker",
          help: "Branches that already exist keep their names.",
          errors: %{
            required: "Enter how branch names start, such as ryker.",
            git_ref: "Use a name Git allows, such as ryker or bots/ryker, without spaces."
          }
        }
      ]
    },
    %{
      key: :report,
      domain: :report,
      kind: :singleton,
      schema: Settings.Report,
      title: "When and where it posts",
      description:
        "Ryker posts its report in one Slack channel, once a week, at the day and time you " <>
          "choose. It stays off until you turn it on.",
      fields: [
        %{
          name: :weekly_self_report_enabled,
          kind: :boolean,
          label: "Post a weekly report",
          help:
            "The first report goes out at the next day and time below, not when you turn it on."
        },
        %{name: :channel_ref, kind: :text, label: "Slack channel"},
        %{name: :weekday, kind: :select, label: "Day", options: @weekdays},
        %{name: :local_time, kind: :time, label: "Time"},
        %{
          name: :timezone,
          kind: :text,
          label: "Time zone",
          placeholder: "Europe/Kyiv",
          help: "The day and time are read in this zone, such as Europe/Kyiv or America/New_York."
        }
      ]
    },
    %{
      key: :learning,
      domain: :learning,
      kind: :singleton,
      schema: Settings.Learning,
      title: "Learning",
      description:
        "Ryker learns from conversations in the background with a model. Turning it off " <>
          "pauses new batches and lets the running ones finish.",
      fields: [%{name: :enabled, kind: :boolean, label: "Learn from past conversations"}]
    },
    # Every field says what it is for in plain words and, when refused, what
    # to choose (QA, 2026-09-25). A new source starts on what this
    # installation has: its default environment, its only signing
    # credential, Grafana's shape, accepting events.
    %{
      key: :webhooks,
      domain: :webhooks,
      kind: :collection,
      schema: Settings.WebhookSource,
      item_key: :name,
      item_label: "webhook source",
      title: "Webhook sources",
      description:
        "Each source is one sender, such as a Grafana contact point, with its own address.",
      empty: {
        :plug,
        "No webhook sources yet",
        "Add a source for each system that should send events to Ryker."
      },
      fields: [
        %{
          name: :name,
          kind: :text,
          label: "Source name",
          placeholder: "grafana",
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
          placeholder: "1712345678.123456",
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
          placeholder: "service, cluster",
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
    # Each kind of work's help says, under its title, where the bundled worker
    # runs those models, as the code decides it: routing (`Ryker.Admission.Decision`) answers a
    # reply on the conversational class and new or continued work on the
    # standard or deep one; `Ryker.CoopFleet.JobTemplates` uses the models
    # saved for its purpose; `Ryker.Runtime.Assembly` runs work with no
    # repository (an environment without any, or no environment) on the
    # installation's conversation template for every class, a confirmed task on
    # the contributor, schedules on theirs, and a whole incident room on the
    # incident template. Change a sentence only with the code it describes.
    #
    # Each kind of work is an ordered list (Andrew, 2026-09-26: "Can I have
    # fallbacks between models/providers like coop allows?"): the first model
    # is used, and Coop moves to the next when one hits a usage limit or its
    # account's sign-in fails.
    #
    # The Models page is a card per part, each saving on its own like every
    # other settings page (Andrew, 2026-09-27: "why some pages like this have
    # islands while others dont"). Conversation, Standard and Deep work must
    # keep the same accounts in the same order, so they share a card, and a
    # Save, with the routing that picks between them.
    %{
      key: :request_models,
      domain: :work,
      kind: :singleton,
      schema: Settings.Work,
      title: "Requests",
      description:
        "A request can move between Conversation, Standard and Deep work, so these three " <>
          "use the same accounts in the same order. Their models and efforts can differ.",
      fields: [
        %{
          name: :routing_models,
          kind: :ladder,
          label: "Routing",
          help:
            "Runs first on every message and event Ryker picks up, from Slack, Chat, GitHub " <>
              "and webhooks. It decides whether to answer, start work, add it to earlier work " <>
              "or stay quiet, and picks Conversation, Standard or Deep work for it. It runs " <>
              "more often than anything else, so speed and price matter most here.",
          errors: @ladder_errors
        },
        %{
          name: :conversation_models,
          kind: :ladder,
          label: "Conversation",
          help:
            "Writes the replies Ryker can give straight away, without a longer investigation: " <>
              "answers from what it already knows, quick questions and small lookups. Where " <>
              "there is no repository to work in, it does the standard and deep work too.",
          errors: @ladder_errors
        },
        %{
          name: :standard_models,
          kind: :ladder,
          label: "Standard work",
          help:
            "Investigations that use tools: reading code, checking logs, running read-only " <>
              "commands and asking Emisar to run something. Routing picks it for most work " <>
              "that needs more than a quick answer. It also reads each repository to write " <>
              "its RYKER.md.",
          errors: @ladder_errors
        },
        %{
          name: :deep_models,
          kind: :ladder,
          label: "Deep work",
          help:
            "The same kind of work, when routing judges the request hard, ambiguous or risky.",
          errors: @ladder_errors
        }
      ]
    },
    %{
      key: :other_models,
      domain: :work,
      kind: :singleton,
      schema: Settings.Work,
      title: "Other work",
      description:
        "Code changes, schedules, incident rooms and learning each have their own models.",
      fields: [
        %{
          name: :contributor_models,
          kind: :ladder,
          label: "Contributor work",
          help:
            "Tasks that change code, once a person confirms them. When pull requests are on, " <>
              "Ryker opens one for the change.",
          errors: @ladder_errors
        },
        %{
          name: :schedule_models,
          kind: :ladder,
          label: "Scheduled work",
          help:
            "Work that starts on its own when a schedule is due: the reminders and recurring " <>
              "checks people set up by asking Ryker.",
          errors: @ladder_errors
        },
        %{
          name: :incident_models,
          kind: :ladder,
          label: "Incident rooms",
          help:
            "Everything Ryker does in an incident room, the Slack channel it opens for an " <>
              "incident: the investigation and every reply there. It also runs an incident " <>
              "investigated in its own thread instead of a room.",
          errors: @ladder_errors
        },
        %{
          name: :learning_models,
          kind: :ladder,
          label: "Learning",
          help:
            "Reads the messages Ryker picks up in the background, including ones it did not " <>
              "answer, and notes what is worth remembering about each conversation. It doesn't " <>
              "reply, and runs only while learning is on.",
          errors: @ladder_errors
        }
      ]
    },
    # Ryker cannot see which accounts the worker has signed in, so they are
    # listed here and every model above names one of them. Each job freezes
    # this selection; later settings changes apply to new jobs only.
    #
    # An account is a row of its own, in the box the lists of models use
    # (Andrew, 2026-09-27: "I need a way to add more accounts than one!"). One
    # text box of comma-separated accounts never showed how to add a second.
    %{
      key: :model_accounts,
      domain: :work,
      kind: :singleton,
      schema: Settings.Work,
      title: "Model accounts",
      description:
        "Ryker cannot see which accounts the worker has signed in, so list them here. " <>
          "Each model above runs on one of them.",
      fields: [
        %{
          name: :model_accounts,
          kind: :accounts,
          label: "Accounts",
          help:
            "One account per row, as provider@name. Sign an account in on the worker first " <>
              "with scripts/compose.sh model-login claude@work, then add it here. If a model " <>
              "uses an account the worker has not signed in, the worker keeps running the " <>
              "models saved before and shows a warning here.",
          errors: %{
            length: "List at least one account, such as codex@default.",
            format: "Fix the account marked above, then save again.",
            list: "List each account once.",
            in_use: {__MODULE__, :accounts_in_use}
          }
        }
      ]
    },
    # Andrew, 2026-09-27: "build/fine-tune our own super-efficient self hosted
    # model later ... So we can do more on free routing steps more accurately
    # and fallback to large provider models only when needed." Phase 1 only
    # measures (`Ryker.LocalRouting`): in the background the local model is
    # asked the routing prompt the provider already answered, and its own page
    # (`Ryker.ControlPlane.LocalRoutingPage`) shows how often it agrees.
    # Routing never waits for it or uses it. That page links to this card by
    # its anchor.
    %{
      key: :local_routing,
      domain: :work,
      kind: :singleton,
      schema: Settings.Work,
      anchor: "local-routing",
      title: "Local routing model",
      # How it compares is a page of its own, opened from the card's title.
      link: {"See how it compares", "/settings/models/local-routing"},
      description:
        "A small model you run yourself, asked to route each message after the provider model " <>
          "has, to see how often the two agree. Routing doesn't use its answers.",
      help:
        "To try one on the Mac that runs Ryker, run scripts/routing-model-service.sh install, " <>
          "then save http://host.docker.internal:8181/v1 and qwen2.5:3b here. Any server that " <>
          "answers the OpenAI chat API with structured output works too. Every routing prompt, " <>
          "with the message and its conversation, is sent to this endpoint.",
      fields: [
        %{
          name: :local_routing_mode,
          kind: :choice,
          label: "Mode",
          options: @local_routing_modes,
          errors: %{required: "Choose whether to compare the local model in the background."}
        },
        %{
          name: :local_routing_endpoint,
          kind: :text,
          label: "Endpoint",
          placeholder: "http://host.docker.internal:8181/v1",
          help:
            "The server's OpenAI-compatible address, ending in /v1. From Ryker's container, " <>
              "the Mac itself is host.docker.internal.",
          errors: %{
            required:
              "Enter the local model's endpoint, such as http://host.docker.internal:8181/v1.",
            format:
              "Write the endpoint as one http:// or https:// address, such as " <>
                "http://host.docker.internal:8181/v1, without a user name or query.",
            insecure:
              "Use https for a server on another network. Plain http is only for this " <>
                "machine (localhost, host.docker.internal) or a private address such as " <>
                "192.168.1.20."
          }
        },
        %{
          name: :local_routing_model,
          kind: :text,
          label: "Model",
          placeholder: "qwen2.5:3b",
          help: "The model's name as the server lists it, such as qwen2.5:3b.",
          errors: %{
            required: "Enter the model's name as the server lists it, such as qwen2.5:3b.",
            format:
              "Write the model's name without spaces, as the server lists it, such as " <>
                "qwen2.5:3b."
          }
        }
      ]
    },
    # A worker enrols under a workspace name and reports it on every sync;
    # people know it as the install the worker belongs to. Sessions kept ready
    # are started by `Ryker.Admission.ReadyPool` on that install.
    %{
      key: :work,
      domain: :work,
      kind: :singleton,
      schema: Settings.Work,
      title: "Where work runs",
      description:
        "The worker install that runs Ryker's work, and how many routing sessions it keeps ready.",
      fields: [
        %{
          name: :workspace_ref,
          kind: :select,
          label: "Worker install",
          options: :workspaces,
          help:
            "Which worker install runs Ryker's work. " <>
              "A worker reports its install name when it connects. " <>
              "Only for workers you run yourself: the bundled worker needs no change here."
        },
        %{
          name: :ready_routing_sessions,
          kind: :integer,
          label: "Routing sessions kept ready",
          min: 0,
          max: Settings.Work.maximum_ready_routing_sessions(),
          help:
            "Ryker starts this many routing sessions ahead of time so a new message is " <>
              "answered sooner. Each is used for one message only. 0 turns this off.",
          errors: %{
            number:
              "Choose a whole number from 0 to #{Settings.Work.maximum_ready_routing_sessions()}.",
            required:
              "Choose a whole number from 0 to #{Settings.Work.maximum_ready_routing_sessions()}."
          }
        }
      ]
    },
    # Listed in the order the limits must keep: each of the first four at
    # least as long as the one above it. Conversation memory only has to
    # outlast the first. Routing examples come last: a copy kept only while a
    # person keeps them on, ordered against nothing.
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
          help:
            "The words themselves: messages people sent, every prompt and answer of a model " <>
              "call, and what each tool call sent and got back. This is most of the data. Once " <>
              "deleted, a request's page still shows each step, without the text."
        },
        %{
          name: :closed_work_seconds,
          kind: :days,
          label: "Finished work",
          help:
            "Ryker's records of closed incident rooms and of task cards in Slack, which take " <>
              "little space. Working copies of repositories are cleaned up separately (see " <>
              "Working copies)."
        },
        %{
          name: :episode_history_seconds,
          kind: :days,
          label: "Request history",
          help:
            "The steps behind each finished request's page: decisions, work turns, approvals, " <>
              "pull requests and schedule runs, without the words above. Once deleted, " <>
              "the request leaves Activity."
        },
        %{
          name: :audit_data_seconds,
          kind: :days,
          label: "Audit trail",
          help:
            "Who changed settings, instructions, channels and credentials, and when, and " <>
              "what is left of each finished request once its history is gone."
        },
        %{
          name: :conversation_memory_seconds,
          kind: :days,
          label: "Conversation memory",
          help:
            "What Ryker learned from each conversation: learned topics, notes and summaries. " <>
              "Facts someone confirmed for the whole workspace stay regardless."
        },
        %{
          name: :routing_examples_enabled,
          kind: :boolean,
          label: "Keep routing examples for training",
          help:
            "Keeps a copy of each routing decision, what it was asked and how it turned out, " <>
              "to train a smaller model that routes messages later. Off until you turn it on."
        },
        %{
          name: :routing_examples_seconds,
          kind: :days,
          label: "Routing examples",
          help:
            "How long each copy is kept; each is about the size of one routing prompt. Deleting " <>
              "a message or forgetting what Ryker learned from it removes it from every copy at once."
        },
        %{
          name: :work_examples_enabled,
          kind: :boolean,
          label: "Keep work examples for training",
          help:
            "Keeps a copy of each finished piece of work: what the worker was told, what it did, " <>
              "the answer Ryker accepted and how it turned out, to train a self-hosted model to " <>
              "do more of the work later. It includes your code and command output, so it is " <>
              "separate from routing examples. Off until you turn it on."
        },
        %{
          name: :work_examples_seconds,
          kind: :days,
          label: "Work examples",
          help:
            "How long each copy is kept; each is about the size of a long document. Deleting a " <>
              "message or forgetting what Ryker learned from it removes it from every copy at once."
        }
      ]
    },
    %{
      key: :pricing,
      domain: :pricing,
      kind: :collection,
      schema: Settings.PricingRate,
      item_key: :id,
      item_label: "price",
      title: "Prices",
      description: "Ryker uses these to estimate cost when the provider does not report it.",
      empty:
        {:usage, "No prices yet", "Add a price so Ryker can estimate what each model costs."},
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
          placeholder: "0.00",
          group: "US dollars per million tokens"
        },
        %{
          name: :cached_input_usd_per_million,
          kind: :decimal,
          label: "Cached input",
          placeholder: "0.00",
          group: "US dollars per million tokens"
        },
        %{
          name: :output_usd_per_million,
          kind: :decimal,
          label: "Output",
          placeholder: "0.00",
          group: "US dollars per million tokens"
        },
        %{
          name: :reasoning_usd_per_million,
          kind: :decimal,
          label: "Reasoning",
          placeholder: "0.00",
          group: "US dollars per million tokens"
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

  @doc "Fields grouped for a readable form while preserving their declared order."
  def field_groups(section) do
    section.fields
    |> Enum.chunk_by(&Map.get(&1, :group))
    |> Enum.map(fn fields -> {Map.get(hd(fields), :group), fields} end)
  end

  @doc "Every kind of work's list of models, in the order the Models page shows them."
  @spec ladder_fields() :: [map()]
  def ladder_fields,
    do: for(section <- @sections, field <- section.fields, field.kind == :ladder, do: field)

  @doc "The words a composite control shows for one of its parts."
  @spec subfield_label(String.t()) :: String.t()
  def subfield_label(subfield), do: Map.get(@subfield_labels, subfield, subfield)

  @doc "What a composite control's part looks like when filled in, shown while it is empty."
  @spec subfield_placeholder(String.t()) :: String.t() | nil
  def subfield_placeholder(subfield), do: Map.get(@subfield_placeholders, subfield)

  @doc "The longest limit, in days, any kind of data can be kept."
  def longest_days, do: @longest_days

  @spec fetch(atom() | String.t()) :: {:ok, map()} | :error
  def fetch(key) do
    case Enum.find(@sections, &(&1.key == key or Atom.to_string(&1.key) == key)) do
      nil -> :error
      section -> {:ok, section}
    end
  end

  @doc "Option pairs for a select, resolved against the current settings view."
  @spec options(map(), map()) :: [{String.t(), String.t()}]
  def options(%{options: :environments}, view),
    do: Enum.map(Environments.ordered(view.snapshot.environments), &{&1.ref, &1.display_name})

  def options(%{options: :webhook_presets}, _view) do
    Enum.map(
      Webhooks.Presets.all(),
      &{Atom.to_string(&1.adapter_kind), &1.title, &1.description}
    )
  end

  def options(%{options: :slack_channels}, view) do
    for %{workspace_ref: workspace, channel_ref: channel} <- view.slack_channels,
        do: {ConversationRef.slack(workspace, channel), Slack.Names.name(workspace, channel)}
  end

  def options(%{options: :webhook_secrets}, %{webhook_secret_names: names}) when is_list(names),
    do: Enum.map(names, &{&1, &1})

  def options(%{options: :webhook_secrets}, _view), do: []

  def options(%{options: :workspaces}, view) do
    Enum.map(
      view.worker_installs,
      &{&1.ref, "#{&1.ref} · #{&1.eligible} of #{&1.workers} #{workers(&1.workers)} ready"}
    )
  end

  def options(%{options: options}, _view) when is_list(options), do: options

  @doc """
  The models one model choice offers, under their provider: every model a
  saved price covers, for each provider the worker runs, and any model this
  kind of work already has, priced or not, so choosing never loses it. Every
  choice on the page lists them in one order: QA, 2026-09-25, found each
  select putting its own saved model first, eight orders for one list.
  """
  @spec ladder_models(map(), [String.t()], [map()]) :: [{String.t(), [{String.t(), String.t()}]}]
  def ladder_models(view, saved, entries) do
    priced = MapSet.new(view.snapshot.pricing_rates, & &1.execution_target)

    kept =
      Enum.map(saved, &ladder_entry(&1)["model"]) ++ Enum.map(entries, & &1["model"])

    (Enum.filter(priced, &(provider(&1) in Settings.Work.providers())) ++ kept)
    |> Enum.filter(&String.contains?(&1, ":"))
    |> Enum.uniq()
    |> Enum.group_by(&provider/1)
    |> Enum.sort_by(fn {provider, _models} -> provider_order(provider) end)
    |> Enum.map(fn {provider, models} ->
      {Work.ExecutionTarget.provider_name(provider),
       models
       |> Enum.sort()
       |> Enum.map(&{&1, model_name(&1) <> if(&1 in priced, do: "", else: " (no price)")})}
    end)
  end

  @doc "The reasoning efforts a model choice offers, in the words every page uses."
  @spec ladder_efforts() :: [{String.t(), String.t()}]
  def ladder_efforts,
    do: Enum.map(Settings.Work.efforts(), &{&1, Work.ExecutionTarget.effort_name(&1)})

  @doc "The accounts listed under Model accounts for the provider of `model`."
  @spec ladder_accounts(map(), String.t()) :: [String.t()]
  def ladder_accounts(view, model) do
    provider = provider(model)

    for account <- view.snapshot.work.model_accounts,
        [^provider, name] <- [String.split(account, "@", parts: 2)],
        do: name
  end

  @doc """
  One step on a list of models in a draft: add a fallback, remove an entry,
  or move one up or down. A step the list cannot take leaves it as it is.

  A new fallback is never a copy of the entry above it, which Save refuses
  (QA, 2026-09-26). It starts as the same model on the next listed account of
  that provider the list does not use yet, after that entry's account and
  then from the top, since the same model on another account is the fallback
  most often wanted. With every account in use, its model waits to be chosen.
  """
  @spec ladder_step([map()], String.t(), integer() | nil, map()) :: [map()]
  def ladder_step(entries, "add", _index, view) do
    if length(entries) < Settings.Work.most_models(),
      do: entries ++ [next_entry(entries, view)],
      else: entries
  end

  def ladder_step(entries, "remove", index, _view)
      when length(entries) > 1 and is_integer(index) and index in 0..(length(entries) - 1)//1,
      do: List.delete_at(entries, index)

  def ladder_step(entries, "up", index, _view)
      when is_integer(index) and index in 1..(length(entries) - 1)//1,
      do: swap(entries, index - 1)

  def ladder_step(entries, "down", index, _view)
      when is_integer(index) and index in 0..(length(entries) - 2)//1,
      do: swap(entries, index)

  def ladder_step(entries, _action, _index, _view), do: entries

  defp next_entry([], _view), do: Map.new(@ladder_parts, &{&1, ""})

  defp next_entry(entries, view) do
    last = List.last(entries)
    provider = provider(last["model"])
    used = for entry <- entries, provider(entry["model"]) == provider, do: entry["account"]

    {before, rest} =
      Enum.split_while(ladder_accounts(view, last["model"]), &(&1 != last["account"]))

    case Enum.find(Enum.drop(rest, 1) ++ before, &(&1 not in used)) do
      nil -> %{last | "model" => "", "account" => ""}
      account -> %{last | "account" => account}
    end
  end

  defp swap(entries, index) do
    {first, [a, b | rest]} = Enum.split(entries, index)
    first ++ [b, a | rest]
  end

  @doc "What an empty account row shows: how an account is written."
  @spec account_placeholder() :: String.t()
  def account_placeholder, do: "provider@name, such as claude@work"

  @doc """
  One step on the list of model accounts in a draft: add an empty row, or
  remove one. An account a saved model still runs on stays, and the refusal
  names those models; a second row with the same account keeps it listed, so
  that one goes. A step the list cannot take leaves it as it is.
  """
  @spec account_step([String.t()], String.t(), integer() | nil, map()) ::
          {:ok, [String.t()]} | {:refused, String.t()}
  def account_step(entries, "add", _index, _view) do
    if length(entries) < Settings.Work.most_accounts(),
      do: {:ok, entries ++ [""]},
      else: {:ok, entries}
  end

  def account_step(entries, "remove", index, view)
      when length(entries) > 1 and is_integer(index) and index in 0..(length(entries) - 1)//1 do
    kept = List.delete_at(entries, index)
    account = entries |> Enum.at(index) |> String.trim()

    cond do
      account in Enum.map(kept, &String.trim/1) -> {:ok, kept}
      sentence = in_use(view, [account]) -> {:refused, sentence}
      true -> {:ok, kept}
    end
  end

  def account_step(entries, _action, _index, _view), do: {:ok, entries}

  @doc """
  What removing `accounts` would strand, as one sentence: each of them a
  saved model still runs on, those models and the kinds of work they are for,
  and what to do first. Nil when no saved model runs on any of them.
  """
  @spec in_use(map(), [String.t()]) :: String.t() | nil
  def in_use(view, accounts) do
    uses =
      for field <- ladder_fields(),
          model <- Map.get(view.snapshot.work, field.name) || [],
          account <- [Settings.Work.account(model)],
          account in accounts,
          do: {account, (Work.ExecutionTarget.parts(model) || %{model: model}).model, field.label}

    if uses != [], do: stranded(uses)
  end

  defp stranded(uses) do
    accounts = uses |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    models = uses |> Enum.map(fn {account, model, _label} -> {account, model} end) |> Enum.uniq()

    clauses =
      for account <- accounts do
        runs =
          for {^account, model} <- models,
              do: {model, for({^account, ^model, label} <- uses, uniq: true, do: label)}

        "#{account} still runs #{runs(runs)}"
      end

    Enum.join(clauses, ", and ") <>
      ". Choose another account for " <>
      if(length(models) == 1, do: "that model", else: "those models") <>
      " above first, then remove " <>
      if(length(accounts) == 1, do: hd(accounts), else: "those accounts") <> "."
  end

  # Each model with the kinds of work it is for. After a model for several,
  # the last is set off by a comma as well, or its "and" would read as one of
  # that model's.
  defp runs(runs) do
    {earlier, [last]} = Enum.split(Enum.map(runs, &run/1), -1)
    several? = runs |> Enum.drop(-1) |> Enum.any?(fn {_model, labels} -> length(labels) > 1 end)

    case earlier do
      [] -> last
      _earlier -> Enum.join(earlier, ", ") <> if(several?, do: ", and ", else: " and ") <> last
    end
  end

  defp run({model, labels}), do: "#{model} for #{Wording.list(labels)}"

  @doc """
  What a refused list of accounts says when a saved model still runs on an
  account it leaves out: those models, and the account they run on.
  """
  @spec accounts_in_use(map(), map()) :: String.t()
  def accounts_in_use(draft, view) do
    kept = draft |> Map.get("model_accounts") |> account_entries() |> Enum.map(&String.trim/1)

    in_use(view, view.snapshot.work.model_accounts -- kept) ||
      "A model above still runs on an account you removed. Choose another account for it " <>
        "first, then remove the account."
  end

  @doc """
  What is wrong with one row of a draft list of accounts, said as it is typed:
  nothing while it is empty or could still become an account. Once a save was
  refused (`finished?`), an unfinished one is marked too.
  """
  @spec account_problem([String.t()], non_neg_integer(), boolean()) :: String.t() | nil
  def account_problem(entries, index, finished?) do
    {earlier, [value | _later]} = Enum.split(entries, index)
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      value in Enum.map(earlier, &String.trim/1) ->
        "#{value} is listed above already. Remove one."

      Settings.Work.account?(value) ->
        nil

      finished? or not Settings.Work.account_start?(value) ->
        account_shape(value)

      true ->
        nil
    end
  end

  defp account_shape(value) do
    known? =
      case String.split(value, "@", parts: 2) do
        [start] -> Enum.any?(Settings.Work.providers(), &String.starts_with?(&1, start))
        [provider, _name] -> provider in Settings.Work.providers()
      end

    if known? do
      "Write it as provider@name, such as claude@work, in lowercase letters, numbers, " <>
        "dashes and underscores."
    else
      "Ryker runs Codex and Claude models, so an account starts with codex@ or claude@."
    end
  end

  defp provider(model) when is_binary(model), do: model |> String.split(":", parts: 2) |> hd()
  defp provider(_model), do: ""

  defp provider_order(provider) do
    {Enum.find_index(Settings.Work.providers(), &(&1 == provider)) ||
       length(Settings.Work.providers()), provider}
  end

  defp model_name(model), do: model |> String.split(":", parts: 2) |> List.last()

  # A saved model as the form holds it: the provider and model together, as
  # its price names it, then its effort and its account.
  defp ladder_entry(target) do
    case Work.ExecutionTarget.parts(target) do
      %{provider: provider, model: model} = parts ->
        %{
          "model" => "#{provider}:#{model}",
          "effort" => parts.effort || "",
          "account" => parts.account || ""
        }

      nil ->
        Map.new(@ladder_parts, &{&1, ""})
    end
  end

  # The entries of a submitted list, in the order the form numbered them. A
  # draft already holds them as a list.
  defp numbered(entries) when is_list(entries), do: Enum.take(entries, @list_bound)

  defp numbered(%{} = numbered) do
    numbered
    |> Enum.flat_map(fn {index, entry} ->
      case Integer.parse(to_string(index)) do
        {position, ""} when position >= 0 -> [{position, entry}]
        _not_a_position -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@list_bound)
    |> Enum.map(&elem(&1, 1))
  end

  defp numbered(_mismatched), do: []

  defp ladder_entries(value), do: value |> numbered() |> Enum.map(&ladder_fields/1)
  defp account_entries(value), do: value |> numbered() |> Enum.map(&text/1)

  defp ladder_fields(%{} = entry), do: Map.new(@ladder_parts, &{&1, text(Map.get(entry, &1))})
  defp ladder_fields(_mismatched), do: Map.new(@ladder_parts, &{&1, ""})

  # An entry missing a part becomes a model the settings refuse by its shape.
  defp ladder_target(entry), do: "#{entry["model"]}/#{entry["effort"]}@#{entry["account"]}"

  defp workers(1), do: "worker"
  defp workers(_count), do: "workers"

  @doc """
  What a second price for the same model and day says: which price is
  already there, and the two ways out.
  """
  @spec price_taken(%{String.t() => String.t()}, map()) :: String.t()
  def price_taken(draft, _view) do
    target = Map.get(draft, "execution_target", "")
    model = (Work.ExecutionTarget.parts(target) || %{model: target}).model

    day =
      case Date.from_iso8601(Map.get(draft, "effective_from", "")) do
        {:ok, date} -> Calendar.strftime(date, "%-d %b %Y")
        {:error, _invalid} -> "that day"
      end

    "#{model} already has a price from #{day}. Choose another day, or edit that price."
  end

  @doc "Whether a token rate prices this model, so its cost can be estimated."
  @spec priced?(String.t(), map()) :: boolean()
  def priced?(target, view) do
    case Work.ExecutionTarget.parts(target) do
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
    case {Settings.default_environment(view.snapshot), view.snapshot.environments} do
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

  defp submitted_value(%{kind: :ladder}, value), do: ladder_entries(value)
  defp submitted_value(%{kind: :accounts}, value), do: account_entries(value)
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

  # A form always sends every list it shows; one it did not send is left as saved.
  defp cast_field(%{kind: :ladder}, ""), do: :skip

  defp cast_field(%{kind: :ladder}, value),
    do: {:ok, value |> ladder_entries() |> Enum.map(&ladder_target/1)}

  # A row added and left empty is not an account.
  defp cast_field(%{kind: :accounts}, ""), do: :skip

  defp cast_field(%{kind: :accounts}, value),
    do: {:ok, value |> account_entries() |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

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

  def row_value(%{kind: :ladder}, models), do: Work.ExecutionTarget.present(models || []).compact
  def row_value(%{kind: :accounts}, accounts), do: Enum.join(accounts || [], ", ")
  def row_value(field, value), do: form_value(field, value)

  # A saved value rendered for its control.
  @spec form_value(map(), term()) :: String.t() | map() | [map()]
  defp form_value(%{kind: :mapping} = field, value),
    do: Map.new(subfields(field), &{&1, Map.get(value || %{}, &1, "")})

  defp form_value(%{kind: :ladder}, models) when is_list(models),
    do: Enum.map(models, &ladder_entry/1)

  defp form_value(%{kind: :ladder}, _absent), do: []
  defp form_value(%{kind: :accounts}, accounts) when is_list(accounts), do: accounts
  defp form_value(%{kind: :accounts}, _absent), do: []

  defp form_value(%{kind: :lifecycle} = field, value),
    do: Map.new(subfields(field), &{&1, Enum.join(Map.get(value || %{}, &1, []), ", ")})

  defp form_value(_field, nil), do: ""
  defp form_value(%{kind: :boolean}, value), do: to_string(value)
  defp form_value(%{kind: :list}, values), do: Enum.join(values, ", ")
  defp form_value(%{kind: :days}, seconds), do: Integer.to_string(div(seconds, @day))

  defp form_value(%{kind: :time}, %Time{} = time),
    do: time |> Time.truncate(:second) |> to_string()

  defp form_value(%{kind: :decimal}, %Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp form_value(_field, value), do: to_string(value)
end
