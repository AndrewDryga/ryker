defmodule Ryker.ControlPlane.SetupPage do
  @moduledoc """
  Onboarding at /setup: the six steps that make Ryker useful, in order, with
  Emisar as an optional fourth between them.

  One step is open at a time, the first that is not done. It says why it
  matters, what it needs and about how long it takes, and has one button to
  the place where it is done. Done steps fold to one line naming what got
  connected; later steps stay readable but quiet. Ryker checks the steps done
  in Slack off by itself, so those say so instead of asking for a click that
  would prove nothing. There is no step for environments: adding the first
  repository creates the Default one, and the repositories step says so.

  Emisar never blocks "ready". Without it Ryker cannot act on anything that
  is running, so it opens in its turn, after the repositories, like any other
  step; it can be skipped, and doing a later step first passes it too. A
  passed Emisar step keeps its place with a quiet way back to it.

  Whether a step is done comes from `SettingsView` (`setup.steps`), the same
  facts the sidebar counts; this module only presents them. The Slack, GitHub
  and Emisar steps say their state in the words every page uses
  (`Integrations`), but only when it is worth knowing: a step that is half
  done, such as verified Slack tokens with nobody to manage Ryker, or broken
  is titled and timed by what is left, and one only not done yet adds nothing
  to its own title.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{Components, Integrations, Kit, Paths}

  @type status :: :done | :current | :later | :skipped

  # The required steps (`SettingsView.setup_steps/0`) with Emisar, the one
  # optional step, fourth: what it lets Ryker do follows from the code it
  # can reach, and the Slack steps after it are checked off by themselves.
  @order [:slack, :github, :repositories, :emisar, :invited, :channel_environment, :request]
  @optional [:emisar]

  @doc """
  The steps in order, each with whether it is done, current, later or, for
  the optional step, skipped. The current step is the first one not done,
  even when a later step already is: setup goes in order, and a done later
  step keeps its check. The optional step is passed once it is skipped
  (`skipped`) or a step after it is done, so it never holds the open step
  after setup moved on without it.
  """
  @spec steps(map(), [atom()]) :: [map()]
  def steps(view, skipped \\ []) do
    done = Map.put(view.setup.steps, :emisar, Integrations.emisar(view).status == :on)
    passed = Enum.filter(@optional, &(&1 in skipped or done_after?(&1, done)))
    current = Enum.find_index(@order, &(not Map.fetch!(done, &1) and &1 not in passed))

    for {key, index} <- Enum.with_index(@order) do
      status =
        cond do
          Map.fetch!(done, key) -> :done
          index == current -> :current
          is_nil(current) or index < current -> :skipped
          true -> :later
        end

      key
      |> step(view)
      |> Map.merge(%{key: key, status: status, optional: key in @optional})
    end
  end

  defp done_after?(key, done) do
    @order
    |> Enum.drop_while(&(&1 != key))
    |> tl()
    |> Enum.any?(&Map.fetch!(done, &1))
  end

  @doc "How far the required steps are: done, how many there are, and about how many minutes are left."
  @spec progress([map()]) :: %{done: non_neg_integer(), total: pos_integer(), minutes: integer()}
  def progress(steps) do
    required = Enum.reject(steps, & &1.optional)
    open = Enum.reject(required, &(&1.status == :done))

    %{
      done: length(required) - length(open),
      total: length(required),
      minutes: Enum.sum_by(open, & &1.minutes)
    }
  end

  @doc "The page's sentence under its title."
  @spec description(map()) :: String.t()
  def description(%{setup: %{complete: true}}), do: "Everything Ryker needs is connected."

  def description(_view),
    do: "Connect Ryker to Slack and your code, then check it with one real request."

  attr(:view, :map, required: true)
  attr(:params, :map, default: %{}, doc: "The page's query: skip=emisar passes the optional step")

  def render(assigns) do
    steps = steps(assigns.view, skipped(assigns.params))
    progress = progress(steps)

    assigns =
      assign(assigns,
        steps: steps,
        progress: progress,
        complete: assigns.view.setup.complete,
        channel: channel_name(assigns.view),
        bot: bot(assigns.view)
      )

    ~H"""
    <div class="setup">
      <section :if={@complete} class="setup-ready" aria-labelledby="setup-ready-title">
        <span class="setup-ready-mark" aria-hidden="true"><Components.icon name={:check} /></span>
        <div>
          <h2 id="setup-ready-title">Ryker is ready</h2>
          <p>
            Mention @{@bot} in {@channel || "a channel it is in"} and it answers there. You can
            also ask it anything in Chat.
          </p>
          <div class="setup-ready-actions">
            <.link navigate="/conversations" class="ui-button primary">Open Chat</.link>
            <.link navigate="/channels" class="ui-button secondary">See channels</.link>
          </div>
        </div>
      </section>

      <div :if={!@complete} class="setup-progress">
        <p id="setup-progress-text">
          <strong>{@progress.done} of {@progress.total}</strong>
          required steps done · {minutes(@progress.minutes)}
        </p>
        <div class="setup-meter" aria-hidden="true">
          <span
            :for={step <- @steps}
            data-done={to_string(step.status == :done)}
            data-optional={to_string(step.optional)}
          ></span>
        </div>
      </div>

      <Kit.section_head
        :if={@complete}
        title="What is set up"
        lede="Change any of these on its own page."
      />
      <ol
        class="setup-steps"
        aria-label="Setup steps"
        aria-describedby={if !@complete, do: "setup-progress-text"}
      >
        <li
          :for={{step, number} <- Enum.with_index(@steps, 1)}
          id={"setup-#{step.key}"}
          class="setup-step"
          data-state={step.status}
          data-optional={step.optional && "true"}
          aria-current={if step.status == :current, do: "step"}
        >
          <span class="setup-marker" aria-hidden="true">
            <Components.icon :if={step.status == :done} name={:check} />
            <span :if={step.status != :done}>{number}</span>
          </span>
          <.done :if={step.status == :done} step={step} />
          <.current :if={step.status == :current} step={step} />
          <.later :if={step.status in [:later, :skipped]} step={step} />
        </li>
      </ol>
    </div>
    """
  end

  defp skipped(%{"skip" => "emisar"}), do: [:emisar]
  defp skipped(_params), do: []

  attr(:step, :map, required: true)

  defp done(assigns) do
    ~H"""
    <div class="setup-step-body">
      <div class="setup-step-done">
        <p class="setup-step-line">
          <span class="sr-only">Done: </span><strong>{@step.done_title}</strong>
          <span :if={@step.summary} class="setup-step-summary">· {@step.summary}</span><span
            :if={@step[:link]}
            class="setup-step-summary"
          > · <.link navigate={@step.link.href}>{@step.link.label}</.link></span>
          <Kit.state :if={@step[:state]} tone={elem(@step.state, 0)} word={elem(@step.state, 1)} />
        </p>
        <p :if={@step[:broken] && @step[:reason]} class="setup-step-reason">{@step.reason}</p>
      </div>
      <.link :if={@step[:manage]} navigate={@step.manage.href} class="setup-step-manage">
        {@step.manage.label}<span class="sr-only">{" " <> @step.done_title}</span>
      </.link>
    </div>
    """
  end

  attr(:step, :map, required: true)

  defp current(assigns) do
    ~H"""
    <div class="setup-step-body">
      <.title step={@step} />
      <p class="setup-step-why">{@step.why}</p>
      <.status :if={@step[:state]} step={@step} />
      <p :if={@step[:note]} class="setup-step-note">{@step.note}</p>
      <p :if={@step[:how]} class="setup-step-how">
        {@step.how}
        <span :if={@step[:command]} class="setup-command">
          <code>{@step.command}</code><button
            type="button"
            class="copy-value"
            data-copy-value={@step.command}
            aria-label={"Copy #{@step.command}"}
          ><Components.icon name={:copy} /><span
            class="sr-only"
            data-copy-status
            aria-live="polite"
          ></span></button>
        </span>
        <q :if={@step[:example]}>{@step.example}</q>
      </p>
      <dl class="setup-step-facts">
        <div :if={@step[:needs]}>
          <dt>You need</dt>
          <dd>{@step.needs}</dd>
        </div>
        <div>
          <dt>Takes</dt>
          <dd>{minutes(@step.minutes, "about")}</dd>
        </div>
        <div :if={@step[:detected]}>
          <dt>Then</dt>
          <dd>{@step.detected}</dd>
        </div>
      </dl>
      <div :if={@step[:action]} class="setup-step-actions">
        <.link
          :if={!@step.action[:external]}
          navigate={@step.action.href}
          class="ui-button primary"
        >{@step.action.label}</.link>
        <a
          :if={@step.action[:external]}
          href={@step.action.href}
          class="ui-button primary"
          target="_blank"
          rel="noopener noreferrer"
        >{@step.action.label}<span class="sr-only"> (opens Slack)</span></a>
        <.link :if={@step.optional} patch={"/setup?skip=#{@step.key}"} class="ui-button secondary">
          Skip for now
        </.link>
      </div>
    </div>
    """
  end

  attr(:step, :map, required: true)

  # A later step is quiet unless what it connects is half done or broken:
  # that is worth knowing before its turn comes. A skipped one keeps a quiet
  # way back to it.
  defp later(assigns) do
    ~H"""
    <div class="setup-step-body">
      <.title step={@step} />
      <p :if={!@step[:state]} class="setup-step-short">{@step.short}</p>
      <.status :if={@step[:state]} step={@step} />
      <.link
        :if={@step.status == :skipped and @step[:action]}
        navigate={@step.action.href}
        class="setup-step-back"
      >{@step.action.label}</.link>
    </div>
    """
  end

  attr(:step, :map, required: true)

  defp title(assigns) do
    ~H"""
    <div class="setup-step-head">
      <h3 class="setup-step-title">{@step.title}</h3>
      <span :if={@step.optional} class="entity-tag">Optional</span>
    </div>
    """
  end

  attr(:step, :map, required: true)

  # Where the step's connection stands, when that is more than not done yet:
  # the dot and word on their own line, the reason under it.
  defp status(assigns) do
    ~H"""
    <div class="setup-step-status">
      <Kit.state tone={elem(@step.state, 0)} word={elem(@step.state, 1)} />
      <p :if={@step[:reason]}>{@step.reason}</p>
    </div>
    """
  end

  # Steps --------------------------------------------------------------------

  # Verified tokens leave one thing to do, choosing who can manage Ryker, so
  # the step says the state every page says and asks only for that.
  defp step(:slack, view) do
    slack = Integrations.slack(view)
    finishing = slack.status == :off

    %{
      title: if(finishing, do: "Finish connecting Slack", else: "Connect Slack"),
      short: "Paste the two tokens from your Slack app.",
      why:
        "Ryker works with your team in Slack: it reads the channels it is invited to and replies there.",
      needs:
        if(finishing,
          do: "The people in your workspace who should change Ryker's settings from Slack",
          else: "A Slack app for Ryker, with its app token (xapp-…) and bot token (xoxb-…)"
        ),
      state: worth_knowing(slack, :state),
      reason: worth_knowing(slack, :reason),
      broken: slack.status == :broken,
      minutes: if(finishing, do: 1, else: 5),
      action: slack.action,
      done_title: "Slack",
      summary: workspace(view.snapshot.slack),
      manage: %{label: "Manage", href: "/integrations/slack"}
    }
  end

  defp step(:github, view) do
    github = Integrations.github(view)
    broken = github.status == :broken
    app = view.snapshot.github.app_slug

    %{
      title: if(broken, do: "Repair GitHub", else: "Connect GitHub"),
      short: "Connect the GitHub App Ryker works through.",
      why:
        "Ryker reads your code and opens pull requests through a GitHub App, so GitHub decides what it can reach.",
      needs: "A GitHub App, its App ID and a private key file (.pem)",
      state: worth_knowing(github, :state),
      reason: worth_knowing(github, :reason),
      broken: broken,
      minutes: 5,
      action: github.action,
      done_title: "GitHub",
      summary: app && "App " <> app,
      manage: %{label: "Manage", href: "/integrations/github"}
    }
  end

  defp step(:repositories, view) do
    %{
      title: "Add repositories",
      short: "Choose the code Ryker may read and work in.",
      why:
        "Ryker only works in the repositories you add, and GitHub checks each person's access on every request.",
      note:
        "Then choose the ones work should use on the Environments page. Channels work in an environment, so a repository no environment has stays unused.",
      needs: "The GitHub App installed on the repositories Ryker should work in",
      minutes: 2,
      action: %{label: "Add repositories", href: "/repositories/new"},
      done_title: "Repositories",
      summary: repositories(view.snapshot.repositories),
      manage: %{label: "Manage", href: "/repositories"}
    }
  end

  # Short of connected, the step is titled by what is missing: nothing
  # connected, an account the running system left out (so it needs repair),
  # an account no work can use yet, or every account paused on purpose.
  defp step(:emisar, view) do
    emisar = Integrations.emisar(view)

    %{
      title:
        case emisar do
          %{status: status} when status in [:not_set_up, :on] -> "Connect Emisar"
          %{status: :broken} -> "Repair Emisar"
          %{state: {:warn, _missing}} -> "Finish connecting Emisar"
          %{state: {:off, _paused}} -> "Emisar is paused"
        end,
      short: "Let Ryker act on your running systems as well as your code.",
      why:
        "With Emisar, Ryker carries out the fixes you ask for, such as restarting a service or rolling back a deploy, once a person approves each risky one. Otherwise it can only tell you what to run.",
      needs: "An Emisar account and an agent API key",
      state: worth_knowing(emisar, :state),
      reason: worth_knowing(emisar, :reason),
      broken: emisar.status == :broken,
      minutes: 3,
      action: emisar.action,
      done_title: "Emisar",
      summary: if(emisar.facts != [], do: Enum.join(emisar.facts, " · ")),
      link:
        emisar.unassigned > 0 &&
          %{label: Integrations.unassigned(emisar.unassigned), href: "/environments"},
      manage: %{label: "Manage", href: "/integrations/emisar"}
    }
  end

  defp step(:invited, view) do
    %{
      title: "Invite Ryker to a channel",
      short: "Add Ryker to a Slack channel. Ryker notices this on its own.",
      why: "Ryker only reads the channels it has been added to.",
      how: "In a channel where your team works, send",
      command: "/invite @" <> bot(view),
      detected: "Ryker notices on its own and checks this step off.",
      minutes: 1,
      action: open_slack(view, nil),
      done_title: "Channels",
      summary: invited(view.setup, channel_name(view)),
      manage: %{label: "Manage", href: "/channels"}
    }
  end

  defp step(:channel_environment, view) do
    channel = Map.get(view.setup, :channel)
    name = channel_name(view)

    %{
      title: "Choose the channel's environment",
      short: "Tell Ryker which code and Emisar account the channel's work uses.",
      why:
        "An environment holds the repositories and the Emisar account work may use. Channels Ryker joins start in the default environment; one joined before there was any has none yet.",
      how:
        "Choose it on the channel's page in Ryker, or press Customize on Ryker's welcome message in #{name || "the channel"}.",
      minutes: 1,
      action: channel_page(channel),
      done_title: "Channel environment",
      summary:
        channel && channel[:environment_name] && "#{name} works in #{channel.environment_name}"
    }
  end

  defp step(:request, view) do
    name = channel_name(view)

    %{
      title: "Send a real request",
      short: "Ask Ryker something real in that channel. Ryker notices the reply on its own.",
      why: "A reply in Slack proves the whole path works, from Slack to your code and back.",
      how: "In #{name || "that channel"}, mention @#{bot(view)} with a real question, such as",
      example: "@#{bot(view)} what does this repository do?",
      detected: "Ryker notices its reply on its own.",
      minutes: 2,
      action: open_slack(view, Map.get(view.setup, :channel)),
      done_title: "First request",
      summary: "Ryker answered in Slack"
    }
  end

  # Helpers ------------------------------------------------------------------

  # An integration's state and reason are worth a line in its step only when
  # it is half done or broken; one not set up yet is what the step asks for.
  defp worth_knowing(%{status: status} = integration, key) when status in [:off, :broken],
    do: Map.fetch!(integration, key)

  defp worth_knowing(_integration, _key), do: nil

  defp workspace(%{workspace_name: name, workspace_ref: ref, bot_name: bot}) do
    case {name || ref, bot} do
      {nil, _bot} -> nil
      {workspace, nil} -> workspace
      {workspace, bot} -> "#{workspace} as @#{bot}"
    end
  end

  defp repositories([]), do: nil

  defp repositories(repositories) do
    names = Enum.map(repositories, &(&1.display_name || &1.ref))

    case names do
      [one] -> one
      [first, second] -> "#{first} and #{second}"
      [first, second | rest] -> "#{first}, #{second} and #{length(rest)} more"
    end
  end

  defp invited(%{invited_channels: count}, name) when is_binary(name) and count > 1,
    do: "Ryker is in #{name} and #{Integrations.count(count - 1, "other channel")}"

  defp invited(_setup, name) when is_binary(name), do: "Ryker is in #{name}"

  defp invited(%{invited_channels: count}, _name),
    do: "Ryker is in #{Integrations.count(count, "channel")}"

  defp channel_name(view) do
    case Map.get(view.setup, :channel) do
      %{workspace_ref: workspace, channel_ref: channel} = found
      when is_binary(workspace) and is_binary(channel) ->
        Integrations.channel_name(found)

      _none ->
        nil
    end
  end

  defp bot(view), do: view.snapshot.slack.bot_name || "ryker"

  defp channel_page(%{workspace_ref: workspace, channel_ref: channel})
       when is_binary(workspace) and is_binary(channel),
       do: %{label: "Choose an environment", href: Paths.channel(workspace, channel)}

  defp channel_page(_none), do: %{label: "See channels", href: "/channels"}

  # The Slack steps are done in Slack, so their one button opens it: the
  # channel itself when Ryker is in one, the workspace otherwise.
  defp open_slack(view, channel) do
    case view.snapshot.slack.workspace_url do
      url when is_binary(url) ->
        base = String.trim_trailing(url, "/")

        case channel do
          %{channel_ref: ref} when is_binary(ref) ->
            %{
              label: "Open #{Integrations.channel_name(channel)} in Slack",
              href: base <> "/archives/" <> URI.encode_www_form(ref),
              external: true
            }

          _workspace ->
            %{label: "Open Slack", href: base <> "/", external: true}
        end

      _unknown ->
        nil
    end
  end

  defp minutes(total, lead \\ nil)
  defp minutes(0, _lead), do: "nothing left to do"
  defp minutes(1, nil), do: "about a minute left"
  defp minutes(total, nil), do: "about #{total} minutes left"
  defp minutes(1, lead), do: "#{lead} a minute"
  defp minutes(total, lead), do: "#{lead} #{total} minutes"
end
