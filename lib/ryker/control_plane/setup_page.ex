defmodule Ryker.ControlPlane.SetupPage do
  @moduledoc """
  Onboarding at /setup: the six steps that make Ryker useful, in order, and
  Emisar as the one strongly recommended extra.

  One step is open at a time, the first that is not done. It says why it
  matters, what it needs and about how long it takes, and has one button to
  the place where it is done. Done steps fold to one line naming what got
  connected; later steps stay readable but quiet. Ryker checks the steps done
  in Slack off by itself, so those say so instead of asking for a click that
  would prove nothing. There is no step for environments: adding the first
  repository creates the Default one, and the repositories step says so.

  Emisar never blocks "ready". It is optional, but without it Ryker cannot act
  on anything that is running, so it has its own panel with its own primary
  action instead of a footnote.

  Whether a step is done comes from `SettingsView` (`setup.steps`), the same
  facts the sidebar counts; this module only presents them. The Slack, GitHub
  and Emisar parts say their state in the words every page uses
  (`Integrations`): a step that is half done, such as verified Slack tokens
  with nobody to manage Ryker, is titled and timed by what is left.
  """

  use Phoenix.Component

  alias Ryker.ControlPlane.{ChannelsPage, Components, Integrations, Kit, SettingsView}

  @type status :: :done | :current | :later

  @doc """
  The required steps in order, each with whether it is done, current or
  later. The current step is the first one not done, even when a later step
  already is: setup goes in order, and a done later step keeps its check.
  """
  @spec steps(map()) :: [map()]
  def steps(view) do
    done = view.setup.steps
    order = SettingsView.setup_steps()
    current = Enum.find(order, &(not Map.fetch!(done, &1)))

    for key <- order do
      status =
        cond do
          Map.fetch!(done, key) -> :done
          key == current -> :current
          true -> :later
        end

      key
      |> step(view)
      |> Map.merge(%{key: key, status: status})
    end
  end

  @doc "How far setup is: steps done, how many there are, and about how many minutes are left."
  @spec progress([map()]) :: %{done: non_neg_integer(), total: pos_integer(), minutes: integer()}
  def progress(steps) do
    open = Enum.reject(steps, &(&1.status == :done))

    %{
      done: length(steps) - length(open),
      total: length(steps),
      minutes: Enum.sum_by(open, & &1.minutes)
    }
  end

  @doc "The page's sentence under its title."
  @spec description(map()) :: String.t()
  def description(%{setup: %{complete: true}}), do: "Everything Ryker needs is connected."

  def description(_view),
    do: "Connect Ryker to Slack and your code, then check it with one real request."

  attr(:view, :map, required: true)

  def render(assigns) do
    steps = steps(assigns.view)
    progress = progress(steps)
    emisar = Integrations.emisar(assigns.view)

    assigns =
      assign(assigns,
        steps: steps,
        progress: progress,
        # "3 of 6 required steps done · 1 recommended · about 6 minutes left":
        # the recommended step is counted apart, because it never blocks ready.
        progress_rest:
          "required steps done" <>
            if(emisar.status == :on, do: "", else: " · 1 recommended") <>
            " · " <> minutes(progress.minutes),
        complete: assigns.view.setup.complete,
        emisar: emisar,
        channel: channel_name(assigns.view),
        bot: bot(assigns.view)
      )

    ~H"""
    <div class="setup">
      <div class="setup-main">
        <section :if={@complete} class="setup-ready" aria-labelledby="setup-ready-title">
          <span class="setup-ready-mark" aria-hidden="true"><Components.icon name={:check} /></span>
          <div>
            <h2 id="setup-ready-title">Ryker is ready</h2>
            <p>
              Mention @{@bot} in {@channel || "a channel it is in"} and it answers there. You can
              also ask it anything in Chat.
            </p>
            <div class="setup-ready-actions">
              <.link
                navigate="/conversations"
                class={["ui-button", if(@emisar.status == :on, do: "primary", else: "secondary")]}
              >Open Chat</.link>
              <.link navigate="/channels" class="ui-button secondary">See channels</.link>
            </div>
          </div>
        </section>

        <div :if={!@complete} class="setup-progress">
          <p id="setup-progress-text">
            <strong>{@progress.done} of {@progress.total}</strong> {@progress_rest}
          </p>
          <div class="setup-meter" aria-hidden="true">
            <span :for={step <- @steps} data-done={to_string(step.status == :done)}></span>
            <span class="setup-meter-extra" data-done={to_string(@emisar.status == :on)}></span>
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
            class="setup-step"
            data-state={step.status}
            aria-current={if step.status == :current, do: "step"}
          >
            <span class="setup-marker" aria-hidden="true">
              <Components.icon :if={step.status == :done} name={:check} />
              <span :if={step.status != :done}>{number}</span>
            </span>
            <.done :if={step.status == :done} step={step} />
            <.current :if={step.status == :current} step={step} />
            <.later :if={step.status == :later} step={step} />
          </li>
        </ol>
      </div>

      <aside class="setup-aside" aria-label="Recommended">
        <.emisar emisar={@emisar} />
      </aside>
    </div>
    """
  end

  attr(:step, :map, required: true)

  defp done(assigns) do
    ~H"""
    <div class="setup-step-body">
      <p class="setup-step-line">
        <span class="sr-only">Done: </span><strong>{@step.done_title}</strong>
        <span :if={@step.summary} class="setup-step-summary">· {@step.summary}</span>
        <Kit.state :if={@step[:state]} tone={elem(@step.state, 0)} word={elem(@step.state, 1)} />
      </p>
      <p :if={@step[:broken]} class="setup-step-note">{@step.note}</p>
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
      <h3 class="setup-step-title">{@step.title}</h3>
      <p class="setup-step-why">{@step.why}</p>
      <p :if={@step[:state]} class="setup-step-note">
        <Kit.state tone={elem(@step.state, 0)} word={elem(@step.state, 1)} />
        <span :if={@step[:note]}>{@step.note}</span>
      </p>
      <p :if={@step[:note] && !@step[:state]} class="setup-step-note">{@step.note}</p>
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
      </div>
    </div>
    """
  end

  attr(:step, :map, required: true)

  # A later step is quiet unless what it connects is broken: that is worth
  # knowing before its turn comes.
  defp later(assigns) do
    ~H"""
    <div class="setup-step-body">
      <h3 class="setup-step-title">{@step.title}</h3>
      <p :if={!@step[:broken]} class="setup-step-short">{@step.short}</p>
      <p :if={@step[:broken]} class="setup-step-short">
        <Kit.state tone={elem(@step.state, 0)} word={elem(@step.state, 1)} />
        <span>{@step.note}</span>
      </p>
    </div>
    """
  end

  attr(:emisar, :map, required: true)

  # Emisar's own panel: what it lets Ryker do and what Ryker cannot do
  # without it, in words, with the one action that fits where it stands.
  defp emisar(%{emisar: %{status: :on}} = assigns) do
    ~H"""
    <section class="setup-emisar" data-state="ready" aria-labelledby="setup-emisar-title">
      <div class="setup-emisar-head">
        <span class="setup-emisar-done" aria-hidden="true"><Components.icon name={:check} /></span>
        <h2 id="setup-emisar-title">Emisar</h2>
        <Kit.state tone={elem(@emisar.state, 0)} word={elem(@emisar.state, 1)} />
      </div>
      <p class="setup-emisar-lede">
        Ryker can carry out the fixes you ask for once a person approves them in Emisar.
      </p>
      <p class="setup-emisar-facts">
        {Enum.join(@emisar.facts, " · ")}<span :if={@emisar.unassigned > 0}> · <.link navigate="/environments">{Integrations.unassigned(
          @emisar.unassigned
        )}</.link></span>
      </p>
      <.link navigate="/integrations/emisar" class="ui-button secondary">Manage Emisar</.link>
    </section>
    """
  end

  # Short of connected, the panel is titled by what is missing: nothing
  # connected, an account the running system left out (so it needs repair),
  # an account no work can use yet (a warning, so a person has something to
  # finish) or every account paused on purpose.
  defp emisar(assigns) do
    assigns =
      assign(assigns,
        title:
          case assigns.emisar do
            %{status: :not_set_up} -> "Connect Emisar"
            %{status: :broken} -> "Repair Emisar"
            %{state: {:warn, _missing}} -> "Finish connecting Emisar"
            %{state: {:off, _paused}} -> "Emisar is paused"
          end,
        paused: match?(%{status: :off, state: {:off, _paused}}, assigns.emisar)
      )

    ~H"""
    <section
      class="setup-emisar"
      id="connect-emisar"
      data-state={@emisar.status}
      aria-labelledby="setup-emisar-title"
    >
      <div class="setup-emisar-head">
        <h2 id="setup-emisar-title">{@title}</h2>
        <span :if={!@paused} class="entity-tag">Recommended</span>
      </div>
      <p :if={@emisar.status == :not_set_up} class="setup-emisar-lede">
        Let Ryker act on your running systems, not only on your code.
      </p>
      <p :if={@emisar.status != :not_set_up} class="setup-emisar-lede">
        <Kit.state tone={elem(@emisar.state, 0)} word={elem(@emisar.state, 1)} />
        {@emisar.reason}
      </p>
      <h3 class="setup-emisar-subhead">With Emisar</h3>
      <ul class="setup-emisar-gains">
        <li>
          <Components.icon name={:check} />
          <span>
            Ryker carries out the operational fixes you ask for, such as restarting a service or
            rolling back a deploy.
          </span>
        </li>
        <li>
          <Components.icon name={:check} />
          <span>
            A person approves each risky action in Emisar before it runs. Ryker never approves on
            anyone's behalf.
          </span>
        </li>
        <li>
          <Components.icon name={:check} />
          <span>
            Once it is decided, Ryker picks the same request back up and reports the result where
            you asked.
          </span>
        </li>
      </ul>
      <h3 class="setup-emisar-subhead">Without it</h3>
      <p class="setup-emisar-without">
        Ryker can investigate and change code, but it cannot act on anything that is running. It
        can only tell you what to run.
      </p>
      <div class="setup-emisar-actions">
        <.link
          navigate={@emisar.action.href}
          class={["ui-button", if(@paused, do: "secondary", else: "primary")]}
        >{@emisar.action.label}</.link>
        <p :if={@emisar.status == :not_set_up}>
          Optional, but strongly recommended. You need an Emisar account and an API token. About
          3 minutes.
        </p>
      </div>
    </section>
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
      state: if(slack.status != :on, do: slack.state),
      note: slack.reason,
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
      state: if(github.status != :on, do: github.state),
      note: github.reason,
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
        "Each one joins the Default environment, which Ryker creates for you. Channels choose an environment, so there is nothing else to set up.",
      needs: "The GitHub App installed on the repositories Ryker should work in",
      minutes: 2,
      action: %{label: "Add repositories", href: "/repositories"},
      done_title: "Repositories",
      summary: repositories(view.snapshot.repositories),
      manage: %{label: "Manage", href: "/repositories"}
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
       do: %{label: "Choose an environment", href: ChannelsPage.path(workspace, channel)}

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
