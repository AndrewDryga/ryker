defmodule Ryker.ControlPlane.WorkerConnect do
  @moduledoc """
  How to connect a worker you run yourself, on Settings › Advanced while no worker has
  connected (Andrew, 2026-11-20, of an install showing only "Worker install: Not set: Ryker
  takes no work": "when worker is not connected would be good to show instructions how to
  connect one"). Until then connecting one meant reading the operations guide and running a
  mix task on the controller for its one-time token.

  The steps carry this installation's own values: the address workers reach it at, the
  certificate authority they must trust, the accounts the Models page names, and a token
  made here that works once, for fifteen minutes. The token is shown once, the way a secret
  is; leaving the page drops it.
  """
  use Phoenix.Component
  alias Ryker.ControlPlane.{Components, Kit}

  @install_command "curl -fsSL https://coop.dryga.com/install.sh | sh"

  attr(:connection, :map,
    default: nil,
    doc: "`%{controller_url, ca_pem}` workers connect with; nil when none can"
  )

  attr(:accounts, :list, required: true, doc: "The model accounts, as provider@name")
  attr(:token, :map, default: nil, doc: "The token just made: `%{token, worker, install}`")
  attr(:error, :string, default: nil, doc: "Why the last token could not be made")

  def card(assigns) do
    assigns = assign(assigns, :install_command, @install_command)

    ~H"""
    <Kit.section_card
      id="worker-connect"
      class="settings-section worker-connect"
      title="Connect a worker"
      lede="No worker has connected, so Ryker takes no work. Run one on a Linux machine with Docker; it connects out to Ryker, so nothing needs to reach it."
    >
      <p :if={!@connection} class="settings-problem" role="status">
        This installation accepts no workers of its own yet. Set <code>RYKER_WORKER_PUBLIC_URL</code>
        to the HTTPS address workers can reach Ryker's worker port at, restart Ryker, and the steps appear here.
      </p>
      <ol
        :if={@connection}
        class="setup-steps worker-connect-steps"
        aria-label="Steps to connect a worker"
      >
        <.step number={1} title="Install co:op on the worker's machine">
          co:op runs the models and their tools in boxes on that machine.
          <:extra>
            <Components.copy_block label="Copy the install command">
              <pre>{@install_command}</pre>
            </Components.copy_block>
          </:extra>
        </.step>
        <.step number={2} title="Set up account access in Ryker">
          Open Settings → Models and save an API key or import the account from Coop.
          Ryker keeps the provider credentials and gives workers temporary access.
          <:extra><.link patch="/settings/models" class="ui-button">Open Models</.link></:extra>
        </.step>
        <.step number={3} title="Make a connection token">
          Name the worker and the install it joins. The token works once, within 15 minutes.
          <:extra>
            <form
              id="worker-connect-form"
              class="settings-form worker-connect-form"
              phx-submit="create-worker-token"
            >
              <div class="settings-field">
                <label for="worker-connect-worker">Worker name</label>
                <input
                  id="worker-connect-worker"
                  name="worker[name]"
                  value={(@token && @token.worker) || "worker-1"}
                  pattern="[A-Za-z0-9_.:\-]+"
                  title="Letters, numbers, dots, dashes, underscores and colons"
                  maxlength="64"
                  required
                />
              </div>
              <div class="settings-field">
                <label for="worker-connect-install">Install name</label>
                <p class="settings-help">
                  Workers with the same install name share Ryker's work.
                </p>
                <input
                  id="worker-connect-install"
                  name="worker[install]"
                  value={(@token && @token.install) || "production"}
                  pattern="[A-Za-z0-9_.:\-]+"
                  title="Letters, numbers, dots, dashes, underscores and colons"
                  maxlength="64"
                  required
                />
              </div>
              <div class="settings-actions">
                <button class="ui-button primary" type="submit" phx-disable-with="Making…">
                  {if @token, do: "Make another token", else: "Make token"}
                </button>
                <Components.form_feedback :if={@error} tone={:error} message={@error} />
              </div>
            </form>
          </:extra>
        </.step>
        <.step :if={@token} number={4} title="Connect the worker">
          Run this on the worker's machine and leave it running. After a restart, run the last
          line again without <code>--token-file</code>.
          <:extra>
            <Components.copy_block label="Copy the connect commands">
              <pre id="worker-connect-commands">{commands(@connection, @token)}</pre>
            </Components.copy_block>
          </:extra>
        </.step>
        <.step number={if @token, do: 5, else: 4} title="Choose its install">
          Once the worker connects, choose
          <strong>{(@token && @token.install) || "its install"}</strong>
          under Worker install below and save.
        </.step>
      </ol>
    </Kit.section_card>
    """
  end

  attr(:number, :integer, required: true)
  attr(:title, :string, required: true)
  slot(:inner_block, required: true)
  slot(:extra)

  defp step(assigns) do
    ~H"""
    <li class="setup-step" data-state="guide" id={"worker-connect-#{@number}"}>
      <span class="setup-marker" aria-hidden="true"><span>{@number}</span></span>
      <div class="setup-step-body">
        <p class="setup-step-title">{@title}</p>
        <p class="setup-step-why">{render_slot(@inner_block)}</p>
        {render_slot(@extra)}
      </div>
    </li>
    """
  end

  @doc """
  The shell lines that save the certificate authority and the token where `coop sessions
  connect` reads them, then connect: what step 4 shows to copy.
  """
  @spec commands(%{controller_url: String.t(), ca_pem: String.t()}, %{token: String.t()}) ::
          String.t()
  def commands(%{controller_url: url, ca_pem: pem}, %{token: token}) do
    Enum.join(
      [
        "mkdir -p ~/ryker-worker && chmod 700 ~/ryker-worker",
        "cat > ~/ryker-worker/ca.pem <<'EOF'",
        String.trim_trailing(pem),
        "EOF",
        "printf '%s\\n' '#{token}' > ~/ryker-worker/token",
        "coop sessions connect --controller #{url} --ca-file ~/ryker-worker/ca.pem " <>
          "--state ~/ryker-worker/state --token-file ~/ryker-worker/token"
      ],
      "\n"
    )
  end
end
