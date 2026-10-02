defmodule Ryker.ControlPlane.LocalRoutingUsage do
  @moduledoc """
  The Local routing model section of Usage & cost: how the model you run
  yourself would have routed the messages the provider model routed
  (`Ryker.LocalRouting`), built only from Kit parts.

  One card says where the comparison stands (a dot and a word, the model,
  and the way to its setting in Settings › Models) and the figures for the
  page's period and scope: comparisons run, the share of answers routing's
  checks took (valid) and the share that decided what the provider decided
  (agreed), the median time the local model took beside the provider's, and
  what the provider spent on those messages, which is what a cascade would
  save on each message the local model gets right. A second card lists the
  latest valid answers that would have made Ryker do something else, and a
  third the latest answers routing's checks refused, each saying why in
  plain words; every row opens its request's timeline at the routing call.

  While the mode is off and nothing was compared in the period, the section
  is its title and one line saying so, with the way to the setting.
  """
  use Phoenix.Component

  import Ecto.Query
  import Ryker.ControlPlane.CurrentInputs, only: [visible_preview: 3]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Environments, Kit, Paths, SlackMarkdown}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.Comparison
  alias Ryker.Repo
  alias Ryker.Slack.Names

  @setting "/settings/models#local-routing"
  @listed 10
  @preview_characters 120

  # Why routing's checks refused an answer (`Ryker.LocalRouting.Verdict`),
  # as the rest of a sentence that starts "The local model".
  @refusals %{
    "empty" => "gave no answer",
    "cut_off" => "stopped before its answer was complete",
    "not_json" => "did not answer in routing's format",
    "rejected:unknown_candidate" => "named earlier work that was not offered",
    "rejected:action_not_allowed" => "chose something Ryker may not do with this message",
    "rejected:relation_not_allowed" =>
      "tied the message to earlier work in a way that is not allowed",
    "rejected:reaction_not_allowed" => "chose an emoji that is not allowed here",
    "rejected:reactions_not_available" => "chose an emoji where none may be added",
    "rejected:repository_not_allowed" => "chose a repository it may not use here",
    "rejected:repository_not_available" => "chose a repository where none may be used",
    "rejected:repository_required" => "started work without choosing a repository",
    "rejected:repository_source_not_available" => "chose a branch or commit that was not offered",
    "rejected:source_item_owner" => "took the message from the work it already belongs to",
    "rejected:occurrence_claimed" => "took the message from the work it already belongs to"
  }

  # What each compared field means for what Ryker does next.
  @field_words %{
    "action" => "what to do",
    "episode_ref" => "which earlier work",
    "relation" => "how it relates to earlier work",
    "work_class" => "kind of work",
    "repository" => "repository",
    "repository_source" => "branch or commit",
    "reactions" => "emoji"
  }

  @doc """
  The figures, latest disagreements and latest refused answers since
  `since` (nil for all time) in one execution scope (`live`, `shadow` or
  `all`), for the model saved now.
  """
  @spec project(DateTime.t() | nil, String.t()) :: map()
  def project(since, scope) do
    setting = LocalRouting.setting()
    comparisons = comparisons(since, scope, setting.model)

    %{
      setting: setting,
      figures: figures(comparisons),
      last_settled: last_settled(comparisons),
      disagreements: disagreements(comparisons),
      refusals: refusals(comparisons)
    }
  end

  # The period's comparisons in the page's scope, for the model saved now: a
  # model tried earlier is another model's record.
  defp comparisons(since, scope, model) do
    Comparison
    |> in_period(since)
    |> in_scope(scope)
    |> of_model(model)
  end

  defp in_period(query, nil), do: query
  defp in_period(query, since), do: where(query, [c], c.inserted_at >= ^since)

  defp in_scope(query, "all"), do: query
  defp in_scope(query, "shadow"), do: where(query, [c], c.execution_mode == :shadow)
  defp in_scope(query, _live), do: where(query, [c], c.execution_mode == :live)

  defp of_model(query, nil), do: query
  defp of_model(query, model), do: where(query, [c], c.local_model == ^model)

  defp figures(comparisons) do
    comparisons
    |> figures_query()
    |> Repo.one()
    |> nothing_agreed()
  end

  # With no answer agreeing, the provider spent nothing on agreed messages;
  # the sum over no rows would read as not measured.
  defp nothing_agreed(%{agreed: 0, provider_cost: %Decimal{}} = figures),
    do: %{figures | agreed_cost: Decimal.new(0)}

  defp nothing_agreed(figures), do: figures

  defp figures_query(comparisons) do
    from(c in comparisons,
      select: %{
        compared: filter(count(c.id), c.status == :compared),
        valid: filter(count(c.id), c.status == :compared and c.valid),
        agreed: filter(count(c.id), c.status == :compared and c.agrees),
        waiting: filter(count(c.id), c.status == :pending),
        failed: filter(count(c.id), c.status == :failed),
        local_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'compared')",
            c.local_ms,
            c.status
          ),
        provider_ms:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'compared')",
            c.provider_ms,
            c.status
          ),
        provider_cost: filter(sum(c.provider_cost_usd), c.status == :compared),
        agreed_cost: filter(sum(c.provider_cost_usd), c.status == :compared and c.agrees),
        estimated:
          fragment(
            "COALESCE(bool_or(?) FILTER (WHERE ? = 'compared'), false)",
            c.provider_cost_estimated,
            c.status
          )
      }
    )
  end

  # The comparison that settled last, compared or given up: whether the
  # local model is answering now.
  defp last_settled(comparisons) do
    Repo.one(
      from(c in comparisons,
        where: c.status != :pending,
        order_by: [desc: c.updated_at, desc: c.id],
        limit: 1,
        select: %{status: c.status, last_error: c.last_error}
      )
    )
  end

  defp disagreements(comparisons) do
    comparisons
    |> where([c], c.status == :compared and c.valid and not c.agrees)
    |> latest()
    |> Enum.map(fn row ->
      local =
        case Jason.decode(row.local_answer || "") do
          {:ok, %{} = decision} -> decision
          _unreadable -> %{}
        end

      listed(row, "local-routing",
        text:
          "The provider chose #{decision(row.provider)}. The local model chose #{decision(local)}.",
        meta: ["Differs in " <> Environments.sentence(Enum.map(row.differing, &field_words/1))]
      )
    end)
  end

  defp refusals(comparisons) do
    comparisons
    |> where([c], c.status == :compared and not c.valid)
    |> latest()
    |> Enum.map(
      &listed(&1, "local-routing-refused",
        text:
          "The local model #{refusal(&1.invalid_reason)}. " <>
            "The provider chose #{decision(&1.provider)}.",
        meta: []
      )
    )
  end

  # The latest settled comparisons of one kind, with the message each
  # answered.
  defp latest(comparisons) do
    secrets = InspectionRedactor.configured_secrets()

    from(c in comparisons,
      join: entry in Entry,
      on: entry.id == c.input_id,
      order_by: [desc: c.compared_at, desc: c.id],
      limit: @listed,
      select: %{
        at: c.compared_at,
        conversation: entry.destination_conversation_ref,
        differing: c.differing_fields,
        generation: c.generation,
        input_id: c.input_id,
        invalid_reason: c.invalid_reason,
        local_answer: c.local_answer,
        provider: entry.decision_document,
        text: visible_preview(entry.operational_pruned_at, entry.event_kind, entry.content)
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :name, preview(&1.text, &1.conversation, secrets)))
  end

  defp listed(row, prefix, words) do
    %{
      at: row.at,
      href: Paths.request(row.input_id) <> "#admission-#{row.input_id}-#{row.generation}",
      id: "#{prefix}-#{row.input_id}-#{row.generation}",
      name: row.name,
      text: Keyword.fetch!(words, :text),
      meta: Keyword.fetch!(words, :meta)
    }
  end

  defp refusal("decision:" <> _field), do: "gave a decision routing could not read"
  defp refusal(reason), do: Map.get(@refusals, reason, "gave an answer routing's checks refused")

  defp preview(nil, _conversation, _secrets), do: "Message text no longer available"

  defp preview(text, conversation, secrets) do
    plain =
      text
      |> InspectionRedactor.artifact(secrets: secrets, max_bytes: 4_096)
      |> Map.get(:text)
      |> Kernel.||("")
      |> SlackMarkdown.plain(Names.workspace_from_destination(conversation))
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      plain == "" ->
        "Message text no longer available"

      String.length(plain) > @preview_characters ->
        String.slice(plain, 0, @preview_characters - 1) <> "…"

      true ->
        plain
    end
  end

  # What a decision would have had Ryker do, as the rest of a sentence, in
  # the words Usage names work types with: a reply is always a conversation,
  # and new or continued work is an investigation, standard or deep.
  defp decision(%{"action" => "start_episode", "work_class" => "deep"}),
    do: "to start a deep investigation"

  defp decision(%{"action" => "start_episode"}), do: "to start an investigation"

  defp decision(%{"action" => "continue_episode", "work_class" => "deep"}),
    do: "to continue earlier work as a deep investigation"

  defp decision(%{"action" => "continue_episode"}), do: "to continue earlier work"
  defp decision(%{"action" => "reply"}), do: "to reply"
  defp decision(%{"action" => "quick_reply"}), do: "a quick reply"
  defp decision(%{"action" => "react"}), do: "to add an emoji"
  defp decision(%{"action" => "ignore"}), do: "to leave it"
  defp decision(_unreadable), do: "something it could not read"

  defp field_words(field), do: Map.get(@field_words, field, field)

  # -- Rendering ----------------------------------------------------------------

  @doc "The section as HTML, for the string-built Usage page."
  @spec render(map() | nil) :: iodata()
  def render(nil), do: []

  def render(summary) do
    %{__changed__: nil, summary: summary}
    |> section()
    |> Safe.to_iodata()
  end

  attr(:summary, :map, required: true)

  defp section(assigns) do
    %{setting: setting, figures: figures} = assigns.summary
    measured? = figures.compared + figures.waiting + figures.failed > 0

    assigns =
      assign(assigns,
        disagreements: assigns.summary.disagreements,
        groups: Kit.day_groups(assigns.summary.disagreements, & &1.at, DateTime.utc_now()),
        refusals: assigns.summary.refusals,
        refusal_groups: Kit.day_groups(assigns.summary.refusals, & &1.at, DateTime.utc_now()),
        lede:
          if(setting.mode == :shadow or measured?,
            do:
              "How a small model you run yourself would have routed the messages the " <>
                "provider model routed. Routing uses only the provider model's decision."
          ),
        link:
          if(setting.mode == :shadow, do: "Change it", else: "Turn it on") <>
            " in Settings › Models",
        compared_valid?: figures.valid > 0,
        model: setting.mode == :shadow && setting.model,
        primary: primary(figures),
        secondary: secondary(figures),
        setting_href: @setting,
        state: state(setting.mode, assigns.summary.last_settled)
      )

    ~H"""
    <div id="local-routing" class="usage-local-routing">
      <Kit.section_card title="Local routing model" lede={@lede}>
        <Kit.status_line state={@state}>
          <span :if={@model}> · {@model}</span> · <a href={@setting_href}>{@link}</a>
        </Kit.status_line>
        <Kit.counts :if={@primary != []} items={@primary} label="Local routing model" />
        <Kit.counts
          :if={@secondary != []}
          items={@secondary}
          label="Local routing model, in more detail"
          secondary
        />
      </Kit.section_card>
      <Kit.section_card
        :if={@compared_valid?}
        id="local-routing-differences"
        title="Where it decided differently"
        lede="The latest valid answers that would have made Ryker do something else. Each opens its request."
      >
        <Kit.entity_list :if={@disagreements != []} label="Where it decided differently">
          <Kit.entity_row
            :for={{row, group} <- Enum.zip(@disagreements, @groups)}
            id={row.id}
            name={row.name}
            href={row.href}
            link_row
            text={row.text}
            meta={row.meta}
            at={Kit.clock(row.at)}
            at_time={row.at}
            group={group}
          />
        </Kit.entity_list>
        <Kit.empty
          :if={@disagreements == []}
          variant={:hint}
          icon={:check}
          title="No disagreements in this period"
          text="Every valid answer decided what the provider decided."
        />
      </Kit.section_card>
      <Kit.section_card
        :if={@refusals != []}
        id="local-routing-refused"
        title="Answers routing refused"
        lede="The latest answers that failed the checks every provider answer goes through. Each opens its request."
      >
        <Kit.entity_list label="Answers routing refused">
          <Kit.entity_row
            :for={{row, group} <- Enum.zip(@refusals, @refusal_groups)}
            id={row.id}
            name={row.name}
            href={row.href}
            link_row
            text={row.text}
            at={Kit.clock(row.at)}
            at_time={row.at}
            group={group}
          />
        </Kit.entity_list>
      </Kit.section_card>
    </div>
    """
  end

  defp state(:off, _last), do: {:off, "Off"}

  defp state(:shadow, %{status: :failed, last_error: why}),
    do: {:warn, "Not reaching the local model", why}

  defp state(:shadow, _last), do: {:on, "Comparing"}

  defp primary(%{compared: 0}), do: []

  defp primary(figures) do
    [
      %{
        value: number(figures.compared),
        label: plural(figures.compared, "comparison", "comparisons")
      },
      %{value: percent(figures.valid, figures.compared), label: "valid"},
      %{value: percent(figures.agreed, figures.compared), label: "agreed with the provider"},
      %{value: duration(figures.local_ms), label: "median local time"},
      %{
        value: money(figures.provider_cost, figures.estimated),
        label: "provider cost of these messages"
      }
    ]
  end

  defp secondary(figures) do
    [
      figures.compared > 0 and
        %{value: duration(figures.provider_ms), label: "median provider time"},
      figures.compared > 0 and
        %{
          value: money(figures.agreed_cost, figures.estimated),
          label: "of it on messages the local model agreed on"
        },
      figures.waiting > 0 and %{value: number(figures.waiting), label: "waiting"},
      figures.failed > 0 and
        %{value: number(figures.failed), label: "could not be asked", tone: :warn}
    ]
    |> Enum.filter(& &1)
  end

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp number(n), do: n |> to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp percent(_part, 0), do: "—"
  defp percent(part, whole), do: decimal(part / whole * 100) <> "%"

  # The Usage page's own formats: seconds to one decimal, dollars to the cent
  # or, below a cent, to four places, and ≈ for an estimate.
  defp duration(nil), do: "—"
  defp duration(ms) when ms >= 3_600_000, do: decimal(ms / 3_600_000) <> "h"
  defp duration(ms) when ms >= 60_000, do: decimal(ms / 60_000) <> "m"
  defp duration(ms), do: decimal(ms / 1_000) <> "s"

  defp money(nil, _estimated), do: "Not measured"
  defp money(%Decimal{coef: 0}, _estimated), do: "$0"

  defp money(%Decimal{} = cost, estimated) do
    precision =
      if Decimal.compare(cost, 0) == :gt and Decimal.compare(cost, Decimal.new("0.01")) == :lt,
        do: 4,
        else: 2

    if(estimated, do: "≈ $", else: "$") <>
      Decimal.to_string(Decimal.round(cost, precision), :normal)
  end

  defp decimal(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1) |> String.trim_trailing(".0")
end
