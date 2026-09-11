defmodule Responder.ControlPlane.SettingsSections do
  @moduledoc """
  The editable product settings as data: which sections exist, which typed
  fields each one writes, and how a submitted form becomes typed attributes.

  The catalog is deliberately explicit. A generic settings bag would let a form
  write a column nobody reviewed; here every control names a field that the
  settings changeset already validates, and anything the form cannot type
  (a policy digest, a worker advertisement, a credential value) is not here.
  """

  alias Responder.Settings.{
    Emisar,
    GitHub,
    Learning,
    PricingRate,
    Publication,
    Report,
    Slack
  }

  @day 86_400
  @participation [
    {"mentions", "Only when mentioned"},
    {"proactive", "Join relevant conversations"},
    {"shadow", "Observe silently"}
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
      description:
        "The workspace this installation answers in. Credentials alone never connect Slack: " <>
          "the saved identity below is what binds the deployment's tokens to this workspace.",
      credentials: ["SLACK_BOT_TOKEN", "SLACK_APP_TOKEN"],
      fields: [
        %{name: :enabled, kind: :boolean, label: "Connect Slack"},
        %{name: :workspace_ref, kind: :text, label: "Workspace ID", placeholder: "T0123456789"},
        %{name: :bot_ref, kind: :text, label: "App ID", placeholder: "A0123456789"},
        %{name: :bot_user_ref, kind: :text, label: "Bot user ID", placeholder: "U0123456789"},
        %{
          name: :default_repository_ref,
          kind: :select,
          label: "Default repository",
          options: :repositories,
          help: "Used by channels that have not chosen their own repository context."
        },
        %{
          name: :default_participation,
          kind: :select,
          label: "Default participation",
          options: @participation,
          help:
            "Applies to every channel that has not chosen for itself. " <>
              "Channels with their own choice keep it."
        },
        %{name: :channel_prefix, kind: :text, label: "Incident channel prefix"},
        %{name: :incident_private, kind: :boolean, label: "Create incident channels private"},
        %{
          name: :operators,
          kind: :list,
          label: "Operators",
          help:
            "Slack user IDs allowed to run operator commands. " <>
              "A disconnected Slack does not revoke them; removing them here does."
        },
        %{
          name: :incident_invite_users,
          kind: :list,
          label: "Incident invitees",
          help: "Slack user IDs invited to every incident channel."
        }
      ]
    },
    %{
      key: :github,
      domain: :github,
      kind: :singleton,
      schema: GitHub,
      title: "GitHub",
      description:
        "The GitHub App identity this installation verified. " <>
          "GITHUB_APP_ID in the environment must name the same app, or the connection is refused.",
      credentials: ["GITHUB_APP_PRIVATE_KEY", "GITHUB_WEBHOOK_SECRET"],
      fields: [
        %{name: :enabled, kind: :boolean, label: "Connect GitHub"},
        %{name: :app_id, kind: :integer, label: "App ID"},
        %{name: :app_slug, kind: :text, label: "App slug"}
      ]
    },
    %{
      key: :emisar,
      domain: :emisar,
      kind: :singleton,
      schema: Emisar,
      title: "Emisar",
      description:
        "Watches for approvals on governed actions. Responder can read a pending run " <>
          "and resume its episode; it can never approve one.",
      credentials: ["EMISAR_API_TOKEN"],
      fields: [%{name: :enabled, kind: :boolean, label: "Monitor Emisar approvals"}]
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
        "Optional USD estimates per million tokens. Reported provider cost stays " <>
          "authoritative; a missing rate stays unknown rather than being guessed, and " <>
          "historical estimates keep the rate revision they were priced with.",
      fields: [
        %{name: :execution_target, kind: :text, label: "Execution target"},
        %{name: :input_usd_per_million, kind: :decimal, label: "Input"},
        %{name: :cached_input_usd_per_million, kind: :decimal, label: "Cached input"},
        %{name: :output_usd_per_million, kind: :decimal, label: "Output"},
        %{name: :reasoning_usd_per_million, kind: :decimal, label: "Reasoning"},
        %{name: :effective_from, kind: :date, label: "Effective from"},
        %{name: :provenance, kind: :text, label: "Where this rate came from"}
      ]
    }
  ]

  @spec sections() :: [map()]
  def sections, do: @sections

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

  def options(%{options: options}, _view) when is_list(options), do: options

  @doc "The saved values of one section (or one collection row) as form strings."
  @spec draft(map(), map(), term()) :: %{String.t() => String.t()}
  def draft(section, view, item_key \\ nil)

  def draft(%{kind: :collection} = section, view, item_key) do
    case current_item(section, view, item_key) do
      nil -> Map.new(section.fields, &{field_name(&1), ""})
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
        {:ok, value} -> {:cont, {:ok, Map.put(attributes, field.name, value)}}
        :error -> {:halt, {:error, {:invalid_settings, [{field.name, kind_error(field.kind)}]}}}
      end
    end)
  end

  defp cast_field(%{kind: :boolean}, value), do: {:ok, value in ["true", "on", true]}

  defp cast_field(%{kind: :list}, value) when is_binary(value) do
    {:ok, value |> String.split([",", " ", "\n", "\t"], trim: true) |> Enum.map(&String.trim/1)}
  end

  defp cast_field(%{kind: kind}, "") when kind in [:text, :select], do: {:ok, nil}
  defp cast_field(%{kind: kind}, value) when kind in [:text, :select], do: {:ok, value}

  defp cast_field(%{kind: kind}, "") when kind in [:integer, :days, :decimal, :date],
    do: {:ok, nil}

  defp cast_field(%{kind: :integer}, value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :days}, value) do
    case Integer.parse(value) do
      {days, ""} when days > 0 -> {:ok, days * @day}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :decimal}, value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :date}, value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _invalid -> :error
    end
  end

  defp cast_field(%{kind: :time}, value) do
    case Time.from_iso8601(pad_seconds(value)) do
      {:ok, time} -> {:ok, time}
      _invalid -> :error
    end
  end

  defp pad_seconds(value) when is_binary(value) do
    if String.length(value) == 5, do: value <> ":00", else: value
  end

  defp pad_seconds(value), do: value

  defp kind_error(:days), do: :days
  defp kind_error(:integer), do: :integer
  defp kind_error(:decimal), do: :decimal
  defp kind_error(:date), do: :date
  defp kind_error(:time), do: :time
  defp kind_error(_kind), do: :invalid

  @doc "The form name of a field."
  @spec field_name(map()) :: String.t()
  def field_name(%{name: name}), do: Atom.to_string(name)

  @doc "A saved value rendered for its control."
  @spec form_value(map(), term()) :: String.t()
  def form_value(_field, nil), do: ""
  def form_value(%{kind: :boolean}, value), do: to_string(value)
  def form_value(%{kind: :list}, values), do: Enum.join(values, ", ")
  def form_value(%{kind: :days}, seconds), do: Integer.to_string(div(seconds, @day))

  def form_value(%{kind: :time}, %Time{} = time),
    do: time |> Time.truncate(:second) |> to_string()

  def form_value(%{kind: :decimal}, %Decimal{} = value), do: Decimal.to_string(value, :normal)
  def form_value(_field, value), do: to_string(value)

  @doc "Days for a stored horizon, and the exact seconds when they are not whole days."
  @spec horizon(non_neg_integer()) :: %{
          days: non_neg_integer(),
          exact_seconds: pos_integer() | nil
        }
  def horizon(seconds) do
    %{days: div(seconds, @day), exact_seconds: if(rem(seconds, @day) != 0, do: seconds)}
  end

  defp display_name(%{ref: ref, display_name: nil}), do: ref
  defp display_name(%{ref: ref, display_name: name}), do: "#{name} (#{ref})"
end
