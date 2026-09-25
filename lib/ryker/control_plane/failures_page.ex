defmodule Ryker.ControlPlane.FailuresPage do
  @moduledoc """
  Failures: the work Ryker could not finish on its own, and one failure's own
  page.

  On 2026-09-24 Andrew opened this page, saw two cards reading "Working-copy
  cleanup stopped" over a big "Resume cleanup" button, and asked what he was
  meant to learn, what the button does, whether it would work, and why Ryker
  could not do it by itself. Each row now answers those four questions in
  that order: its name says what stopped, its state says whether a retry
  should work, its text says who is affected and why Ryker stopped, and the
  line under its facts says what the button does before anyone presses it.
  An action that cannot work yet is never the row's button; the row says what
  has to change first and links to where to change it.

  The words come from `FailureExplanation`, which the confirmation pages read
  too, so the page and the confirmation cannot describe one action two ways.
  Rows are Kit rows grouped by impact: failures that leave someone without a
  reply, an update or a result come first, cleanup nobody waits on second.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    Components,
    FailureExplanation,
    FailureProjection,
    Kit,
    ShortTime,
    SlackMarkdown
  }

  @doc "The one sentence under the page title."
  @spec description() :: String.t()
  def description,
    do:
      "Work Ryker could not finish on its own. Each one says what happened, what it affects and what you can do."

  @doc "The Failures list: the counts, then the failures grouped by who they affect."
  @spec list([map()], DateTime.t()) :: iodata()
  def list(rows, now \\ DateTime.utc_now()) do
    explained = Enum.map(rows, &{&1, FailureExplanation.explain(&1, now)})
    {people, housekeeping} = Enum.split_with(explained, fn {_row, e} -> e.impact == :people end)

    %{
      __changed__: nil,
      people: people,
      housekeeping: housekeeping,
      counts: counts(explained, now),
      now: now
    }
    |> list_view()
    |> Safe.to_iodata()
  end

  defp list_view(assigns) do
    ~H"""
    <div class="failures-page">
      <%= if @people == [] and @housekeeping == [] do %>
        <Kit.empty
          title="Nothing needs you."
          text="When Ryker cannot finish something on its own, such as a reply, a Slack update or a cleanup, it shows up here with what you can do about it."
        />
      <% else %>
        <Kit.counts label="Failures" items={@counts} />
        <section :if={@people != []} class="failures-group" aria-labelledby="affects-people">
          <Kit.section_head
            id="affects-people"
            title="Affects people"
            lede="Someone is missing a reply, an update or a result until these are fixed."
          />
          <Kit.entity_list label="Failures that affect people">
            <.row :for={{row, explanation} <- @people} row={row} e={explanation} now={@now} />
          </Kit.entity_list>
        </section>
        <section :if={@housekeeping != []} class="failures-group" aria-labelledby="housekeeping">
          <Kit.section_head
            id="housekeeping"
            title="Housekeeping"
            lede="Cleanup after finished work. Nobody is waiting on these."
          />
          <Kit.entity_list label="Housekeeping failures">
            <.row :for={{row, explanation} <- @housekeeping} row={row} e={explanation} now={@now} />
          </Kit.entity_list>
        </section>
      <% end %>
    </div>
    """
  end

  @doc """
  The way to older failures and back, under the list.

  The list holds a hundred at a time, newest first. Past that, older failures
  are the next page; past the deepest page the list reads, the page says more
  exist instead of dropping them without a word.
  """
  @spec pager(pos_integer(), :none | :next_page | :unlisted) :: iodata()
  def pager(page, older) do
    listed = FailureProjection.page_size() * FailureProjection.maximum_page()

    %{__changed__: nil, page: page, older: older, listed: listed}
    |> pager_view()
    |> Safe.to_iodata()
  end

  defp pager_view(assigns) do
    ~H"""
    <nav :if={@page > 1 or @older != :none} class="pagination" aria-label="Failure pages">
      <a :if={@page > 1} href={failures_page(@page - 1)}>← Newer failures</a>
      <span>Page {@page}</span>
      <a :if={@older == :next_page} href={failures_page(@page + 1)}>Older failures →</a>
      <span :if={@older == :unlisted}>Only the newest {@listed} failures are listed.</span>
    </nav>
    """
  end

  defp failures_page(1), do: "/failures"
  defp failures_page(page), do: "/failures?page=#{page}"

  # The tile carries the row's tone: a person is needed, it failed, or it is
  # only housekeeping.
  defp tile_tone({tone, _word}) when tone in [:warn, :bad], do: tone
  defp tile_tone(_state), do: :off

  attr(:row, :map, required: true)
  attr(:e, :map, required: true)
  attr(:now, :any, required: true)

  # The button is the recommended option only; an option that cannot work yet
  # is replaced by the change it needs, so the loudest thing on a row is never
  # a step that will fail.
  defp row(assigns) do
    assigns = assign(assigns, :next, assigns.e.next)

    ~H"""
    <Kit.entity_row
      name={@e.title}
      href={FailureExplanation.path(@row)}
      icon={:incident}
      icon_tone={tile_tone(@e.state)}
      state={@e.state}
      text={@e.summary}
      meta={facts(@row, @now)}
      class="failure-row"
    >
      <:details>
        <p class="failure-next"><strong>{@next.lead}</strong> {@next.text}</p>
      </:details>
      <:actions :if={@e.button}>
        <Components.action_button
          :if={@e.button[:path]}
          path={@e.button.path}
          label={@e.button.label}
        />
        <a
          :if={@e.button[:href]}
          class="ui-button secondary"
          href={@e.button.href}
          {external(@e.button.href)}
        >
          {@e.button.label}
        </a>
      </:actions>
    </Kit.entity_row>
    """
  end

  @doc "One failure's own page: what happened, what it affects, what was tried and what can be done."
  @spec detail(map(), DateTime.t()) :: iodata()
  def detail(row, now \\ DateTime.utc_now()) do
    explanation = FailureExplanation.explain(row, now)

    %{
      __changed__: nil,
      row: row,
      e: explanation,
      facts: facts(row, now),
      technical: FailureExplanation.technical(row),
      steps: FailureExplanation.cleanup_steps(row),
      report: get_in(row, [:work_recovery, :model_output])
    }
    |> detail_view()
    |> Safe.to_iodata()
  end

  defp detail_view(assigns) do
    ~H"""
    <div class="failure-page">
      <p class="failure-status">
        <Kit.state tone={elem(@e.state, 0)} word={elem(@e.state, 1)} />
        <span :for={fact <- @facts} class="failure-status-fact">{fact}</span>
      </p>

      <Kit.section_head title="What happened" />
      <div class="failure-prose">
        <p :for={paragraph <- @e.happened}>{paragraph}</p>
      </div>
      <details :if={@report} class="recovery-worker-report failure-report">
        <summary>The worker’s last answer</summary>
        <p class="recovery-attribution">
          The worker wrote this. Ryker has not checked the claims in it.
        </p>
        <div class="recovery-model-output">
          {Phoenix.HTML.raw(SlackMarkdown.preview(@report))}
        </div>
      </details>

      <Kit.section_head title="What it affects" />
      <div class="failure-prose">
        <p :for={paragraph <- @e.affects}>{paragraph}</p>
      </div>

      <Kit.section_head title="What Ryker tried" />
      <div class="failure-prose">
        <p :for={paragraph <- @e.tried}>{paragraph}</p>
      </div>

      <Kit.section_head title="What you can do" lede={@e.options_lede} />
      <Kit.entity_list label="What you can do">
        <Kit.entity_row
          :for={option <- @e.options}
          name={option.label}
          state={option[:outlook]}
          text={option.effect}
          meta={List.wrap(option[:note])}
          class="failure-option"
        >
          <:actions :if={option[:path] || option[:href]}>
            <Components.action_button
              :if={option[:path]}
              path={option.path}
              label={option.label}
              tone={if option[:recommended], do: :primary, else: :secondary}
            />
            <a
              :if={option[:href]}
              class={["ui-button", if(option[:recommended], do: "primary", else: "secondary")]}
              href={option.href}
              {external(option.href)}
            >{option[:link] || option.label}</a>
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>

      <Components.disclosure
        id="failure-technical"
        label="Technical details"
        class="failure-technical"
      >
        <Components.fact_list facts={@technical} />
        <ol :if={@steps != []} class="failure-steps" aria-label="Cleanup steps">
          <li :for={step <- @steps} data-state={step.state}>
            <strong>{step.label}</strong> <span>{step.status}</span>
          </li>
        </ol>
      </Components.disclosure>
    </div>
    """
  end

  # The facts every row and page leads with: the request it belongs to, where
  # it happened, when it stopped and how many times Ryker tried.
  defp facts(row, now) do
    Enum.reject(
      [
        request(row),
        FailureExplanation.place(row),
        stopped(row, now),
        FailureExplanation.attempts(row)
      ],
      &is_nil/1
    )
  end

  defp request(row) do
    case FailureExplanation.request(row) do
      %{href: href, text: text} -> anchor(%{href: href, text: text})
      %{text: text} -> text
      nil -> nil
    end
  end

  # Slack's own links open the Slack app, outside the workspace.
  defp external("https://" <> _), do: [target: "_blank", rel: "noopener noreferrer"]
  defp external(_path), do: []

  defp stopped(%{updated_at: at}, now) when not is_nil(at),
    do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: "stopped "})

  defp stopped(_row, _now), do: nil

  defp anchor(assigns), do: ~H|<a href={@href}>{@text}</a>|

  # "1 affects people · 2 housekeeping · 1 should work if retried · 10 h since
  # the oldest stopped": who is affected first, then what a person can do now.
  defp counts(explained, now) do
    {people, housekeeping} = Enum.split_with(explained, fn {_row, e} -> e.impact == :people end)
    ready = Enum.count(explained, fn {_row, e} -> e.outlook == :ready end)

    [
      if(people != [],
        do: %{
          value: length(people),
          label: if(length(people) == 1, do: "affects people", else: "affect people"),
          tone: :warn
        }
      ),
      if(housekeeping != [], do: %{value: length(housekeeping), label: "housekeeping"}),
      if(ready > 0, do: %{value: ready, label: "should work if retried"}),
      oldest(explained, now)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp oldest(explained, now) do
    explained
    |> Enum.map(fn {row, _e} -> Map.get(row, :updated_at) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(&DateTime.to_unix(utc(&1), :microsecond), fn -> nil end)
    |> case do
      nil -> nil
      at -> %{value: FailureExplanation.age(at, now), label: "since the oldest stopped"}
    end
  end

  defp utc(%DateTime{} = at), do: at
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
