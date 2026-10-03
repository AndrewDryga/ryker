defmodule Ryker.ControlPlane.LocalRoutingPage do
  @moduledoc """
  The local routing model's own page, under Settings › Models beside its
  setting: how the model you run yourself would have routed the live
  messages the provider model routed (`Ryker.LocalRouting`), built only from
  Kit parts. It lived on Usage & cost until Andrew asked, 2026-10-03, "why
  the fuck you added Local routing model and Where it decided differently to
  usage and costs?!"

  A status line says where the comparison stands (a dot and a word, the
  model, and the way to its setting), then a period switch, then the
  figures for the period: comparisons run, the share of answers routing's
  checks took (valid) and the share that decided what the provider decided
  (agreed), the median time the local model took beside the provider's, and
  what the provider spent on those messages, which is what a cascade would
  save on each message the local model gets right. Three tables follow: by
  what the provider decided, how many of the local model's answers were
  usable and matched; what differed when a usable answer did not match; and
  why routing refused the rest. Each row links to its latest message, opened
  at the routing step.
  """
  use Phoenix.Component

  import Ecto.Query

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, Paths, ShortTime}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.Comparison
  alias Ryker.Repo
  alias Ryker.Settings

  @setting "/settings/models#local-routing"
  @path "/settings/models/local-routing"
  @windows [{"24h", "24 hours"}, {"7d", "7 days"}, {"30d", "30 days"}, {"all", "All time"}]

  @doc "Where the page is."
  def path, do: @path

  @doc "The sentence under the page's title."
  def description,
    do:
      "How the small model you run yourself would have routed live messages, compared with " <>
        "the provider model. Routing doesn't use its answers."

  @doc """
  The topics an open page listens to: comparisons queued and settled, and
  the settings, which hold the model it compares.
  """
  def subscriptions,
    do: [{LocalRouting, :subscribe_comparisons, []}, {Settings, :subscribe, []}]

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

    compared = compared(comparisons)

    %{
      setting: setting,
      figures: figures(comparisons),
      last_settled: last_settled(comparisons),
      decisions: decisions(compared),
      differences: differences(compared),
      refusals: refusals(compared)
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

  # The period's settled comparisons, newest first, with what the provider
  # decided for each message.
  @summarized 10_000

  defp compared(comparisons) do
    from(c in comparisons,
      join: entry in Entry,
      on: entry.id == c.input_id,
      where: c.status == :compared,
      order_by: [desc: c.compared_at, desc: c.id],
      limit: @summarized,
      select: %{
        agrees: c.agrees,
        at: c.compared_at,
        differing: c.differing_fields,
        generation: c.generation,
        input_id: c.input_id,
        invalid_reason: c.invalid_reason,
        local_answer: c.local_answer,
        provider: entry.decision_document,
        valid: c.valid
      }
    )
    |> Repo.all()
  end

  # Andrew, 2026-10-03, of the two lists this page had: "the way you built
  # those tables is piece of shit, they are useless, what i am supposed to do
  # or learn by looking at them?" Each table answers one question about
  # whether the local model could route instead: which of the provider's
  # decisions it matches, what it gets wrong when its answer is usable, and
  # why routing could not use the rest. Each row links to its latest message.

  # By what the provider decided: how many of the local model's answers were
  # usable and matched, and what it chose most often when it did not.
  defp decisions(compared) do
    compared
    |> Enum.group_by(&decision_kind(&1.provider))
    |> Enum.map(fn {kind, rows} ->
      valid = Enum.filter(rows, & &1.valid)

      %{
        name: decision_name(kind),
        messages: length(rows),
        valid: length(valid),
        agreed: Enum.count(valid, & &1.agrees),
        instead: instead(Enum.reject(valid, & &1.agrees)),
        latest: hd(rows)
      }
    end)
    |> Enum.sort_by(&{-&1.messages, &1.name})
  end

  defp instead([]), do: nil

  defp instead(rows) do
    {kind, times} =
      rows
      |> Enum.frequencies_by(&decision_kind(local_decision(&1)))
      |> Enum.max_by(fn {kind, times} -> {times, kind} end)

    "#{decision_name(kind)} (#{times})"
  end

  # When its answer was usable but not the provider's: what differed, and
  # how often that was the only difference.
  defp differences(compared) do
    compared
    |> Enum.filter(&(&1.valid and not &1.agrees))
    |> Enum.flat_map(fn row -> Enum.map(row.differing || [], &{&1, row}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {field, rows} ->
      %{
        name: String.capitalize(field_words(field)),
        answers: length(rows),
        only: Enum.count(rows, &(&1.differing == [field])),
        latest: hd(rows)
      }
    end)
    |> Enum.sort_by(&{-&1.answers, &1.name})
  end

  # Why routing could not use its answer.
  defp refusals(compared) do
    compared
    |> Enum.reject(& &1.valid)
    |> Enum.group_by(&refusal(&1.invalid_reason))
    |> Enum.map(fn {words, rows} ->
      %{name: String.capitalize(words), answers: length(rows), latest: hd(rows)}
    end)
    |> Enum.sort_by(&{-&1.answers, &1.name})
  end

  defp local_decision(row) do
    case Jason.decode(row.local_answer || "") do
      {:ok, %{} = decision} -> decision
      _unreadable -> %{}
    end
  end

  # The message a row is about, opened at its routing step.
  defp latest_href(row),
    do: Paths.request(row.input_id) <> "#admission-#{row.input_id}-#{row.generation}"

  defp refusal("decision:" <> _field), do: "gave a decision routing could not read"
  defp refusal(reason), do: Map.get(@refusals, reason, "gave an answer routing's checks refused")

  # What a decision has Ryker do, named the way Usage names work types: a
  # reply is always a conversation, and new or continued work is an
  # investigation, standard or deep.
  defp decision_kind(%{"action" => "start_episode", "work_class" => "deep"}), do: :start_deep
  defp decision_kind(%{"action" => "start_episode"}), do: :start

  defp decision_kind(%{"action" => "continue_episode", "work_class" => "deep"}),
    do: :continue_deep

  defp decision_kind(%{"action" => "continue_episode"}), do: :continue
  defp decision_kind(%{"action" => "reply"}), do: :reply
  defp decision_kind(%{"action" => "quick_reply"}), do: :quick_reply
  defp decision_kind(%{"action" => "react"}), do: :react
  defp decision_kind(%{"action" => "ignore"}), do: :ignore
  defp decision_kind(_unreadable), do: :unreadable

  defp decision_name(:start_deep), do: "A deep investigation"
  defp decision_name(:start), do: "An investigation"
  defp decision_name(:continue_deep), do: "Earlier work, as a deep investigation"
  defp decision_name(:continue), do: "Earlier work"
  defp decision_name(:reply), do: "A reply"
  defp decision_name(:quick_reply), do: "A quick reply"
  defp decision_name(:react), do: "An emoji"
  defp decision_name(:ignore), do: "Leaving it"
  defp decision_name(:unreadable), do: "Something unreadable"

  defp field_words(field), do: Map.get(@field_words, field, field)

  # -- Rendering ----------------------------------------------------------------

  @doc "The page's body for one period (`24h`, `7d`, `30d` or `all`)."
  @spec render(map(), String.t()) :: iodata()
  def render(summary, window) do
    %{__changed__: nil, summary: summary, window: window}
    |> page()
    |> Safe.to_iodata()
  end

  attr(:summary, :map, required: true)
  attr(:window, :string, required: true)

  defp page(assigns) do
    %{setting: setting, figures: figures} = assigns.summary

    assigns =
      assign(assigns,
        decisions: assigns.summary.decisions,
        differences: assigns.summary.differences,
        refusals: assigns.summary.refusals,
        now: DateTime.utc_now(),
        link:
          if(setting.mode == :shadow, do: "Change it", else: "Turn it on") <>
            " in Settings › Models",
        model: setting.mode == :shadow && setting.model,
        primary: primary(figures),
        secondary: secondary(figures),
        setting_href: @setting,
        state: state(setting.mode, assigns.summary.last_settled),
        windows:
          Enum.map(@windows, fn {key, label} ->
            {label, @path <> "?window=" <> key, key == assigns.window}
          end)
      )

    ~H"""
    <div id="local-routing" class="local-routing-page">
      <Kit.status_line state={@state}>
        <span :if={@model}>{@model}</span>
        <a href={@setting_href}>{@link}</a>
      </Kit.status_line>
      <Kit.toolbar>
        <Kit.segmented label="Period" options={@windows} />
      </Kit.toolbar>
      <Kit.section_card
        id="local-routing-figures"
        title="How it compares"
        lede="How the local model did on the live messages routed in this period."
      >
        <Kit.counts :if={@primary != []} items={@primary} label="How it compares" />
        <Kit.counts
          :if={@secondary != []}
          items={@secondary}
          label="How it compares, in more detail"
          secondary
        />
        <Kit.empty
          :if={@primary == [] and @secondary == []}
          variant={:hint}
          icon={:clock}
          title="Nothing compared in this period"
          text="Each message routed while the comparison is on is counted here."
        />
      </Kit.section_card>
      <Kit.section_card
        :if={@decisions != []}
        id="local-routing-decisions"
        title="By what the provider decided"
        lede="For each kind of decision the provider made, how often the local model's answer was usable and matched it."
      >
        <Kit.table label="By what the provider decided" rows={@decisions}>
          <:col :let={row} label="The provider chose">{row.name}</:col>
          <:col :let={row} label="Messages" numeric>{row.messages}</:col>
          <:col :let={row} label="Usable answers" numeric>{row.valid}</:col>
          <:col :let={row} label="Matched" numeric>{row.agreed}</:col>
          <:col :let={row} label="When it differed, it chose">{row.instead || "—"}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
      <Kit.section_card
        :if={@differences != []}
        id="local-routing-differences"
        title="What differed"
        lede="Where its usable answers differed from the provider's."
      >
        <Kit.table label="What differed" rows={@differences}>
          <:col :let={row} label="What differed">{row.name}</:col>
          <:col :let={row} label="Answers" numeric>{row.answers}</:col>
          <:col :let={row} label="The only difference" numeric>{row.only}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
      <Kit.section_card
        :if={@refusals != []}
        id="local-routing-refused"
        title="Why routing refused its answers"
        lede="Answers that failed routing's checks, so routing couldn't have used them."
      >
        <Kit.table label="Why routing refused its answers" rows={@refusals}>
          <:col :let={row} label="The local model">{row.name}</:col>
          <:col :let={row} label="Answers" numeric>{row.answers}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:now, :any, required: true)

  # The latest message a row is about, by when it was routed, opened at its
  # routing step.
  defp latest(assigns) do
    ~H"""
    <a href={latest_href(@row)}>{ShortTime.text(@row.at, @now)}</a>
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
