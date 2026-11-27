defmodule Ryker.ControlPlane.ModelAccountAccess do
  @moduledoc false
  use Phoenix.LiveComponent
  alias Ryker.ControlPlane.{Components, Kit}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       kind: "apikey",
       receive_code: nil,
       error: nil,
       capacity_error: nil,
       removing: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    key = String.replace(assigns.account, "@", ":", global: false)
    saved = Enum.find(assigns.view.credentials, &(&1.kind == :model_account and &1.name == key))

    capacity =
      case Ryker.CoopFleet.model_capacity(assigns.account) do
        {:ok, capacity} -> capacity
        _unavailable -> nil
      end

    socket =
      if socket.assigns[:account] == assigns.account do
        socket
      else
        assign(socket,
          kind: if(saved, do: "apikey", else: "transfer"),
          receive_code: nil,
          error: nil,
          capacity_error: nil,
          removing: false
        )
      end

    {:ok, socket |> assign(assigns) |> assign(saved: saved, capacity: capacity)}
  end

  @impl true
  def handle_event("kind", %{"kind" => kind}, socket) when kind in ["apikey", "transfer"],
    do: {:noreply, assign(socket, kind: kind, receive_code: nil, error: nil)}

  def handle_event("save-key", %{"credential" => %{"secret" => secret}}, socket) do
    save(socket, socket.assigns.commands.put_model_key.(socket.assigns.account, secret))
  end

  def handle_event("receive-code", _params, socket) do
    case socket.assigns.commands.model_receive_code.(socket.assigns.account) do
      {:ok, code} ->
        {:noreply, assign(socket, receive_code: code, error: nil)}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not create a receive code. Try again.")}
    end
  end

  def handle_event("receive-bundle", %{"secret_bundle" => bundle} = params, socket) do
    target = Map.get(params, "target", socket.assigns.account)

    case socket.assigns.commands.receive_model_account.(socket.assigns.account, target, bundle) do
      {:ok, _} = ok ->
        save(socket, ok)

      {:error, :account_already_configured} ->
        {:noreply,
         assign(socket,
           error:
             "That account already has access. Choose an unused name for this provider or add one under Models, then reopen this receive code."
         )}

      {:error, :already_imported} ->
        {:noreply, assign(socket, error: "This bundle was already imported.")}

      {:error, _} ->
        {:noreply,
         assign(socket,
           error:
             "Could not import this bundle. Paste the whole reply made for this receive code."
         )}
    end
  end

  def handle_event("save-concurrency", %{"concurrency" => value}, socket) do
    with {count, ""} <- Integer.parse(value),
         {:ok, :ok} <-
           socket.assigns.commands.set_model_concurrency.(socket.assigns.account, count),
         {:ok, capacity} <- Ryker.CoopFleet.model_capacity(socket.assigns.account) do
      {:noreply, assign(socket, capacity: capacity, capacity_error: nil)}
    else
      _invalid ->
        {:noreply,
         assign(socket,
           capacity_error:
             "Choose a whole number from 0 to 256. The account must have saved access."
         )}
    end
  end

  def handle_event("ask-remove", _params, socket),
    do: {:noreply, assign(socket, removing: true, error: nil)}

  def handle_event("cancel-remove", _params, socket),
    do: {:noreply, assign(socket, removing: false)}

  def handle_event("remove", _params, %{assigns: %{removing: true}} = socket) do
    case socket.assigns.commands.remove_model_account.(socket.assigns.account) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Removed access for #{socket.assigns.account}.")
         |> push_patch(to: "/settings/models")}

      {:error, _reason} ->
        {:noreply, assign(socket, error: "The account could not be removed. Try again.")}
    end
  end

  def handle_event("remove", _params, socket), do: {:noreply, socket}

  defp save(socket, {:ok, _metadata}) do
    {:noreply,
     socket
     |> put_flash(:info, "Saved access for #{socket.assigns.account}.")
     |> push_patch(to: "/settings/models")}
  end

  defp save(socket, {:error, _reason}) do
    {:noreply,
     assign(socket,
       error: "The API key could not be saved. Check the key and try again."
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <Kit.form_card label={"Access for #{@account}"}>
        <div class="settings-form">
          <p class="settings-help">
            Ryker keeps this account's credentials and issues temporary access to its workers.
          </p>
          <p :if={@saved && @kind == "transfer"} class="settings-notice">
            This account already has access. Choose an unused account to import a second login.
          </p>
          <p :if={@saved && @kind == "apikey"} class="settings-notice">
            Access is saved. Saving again replaces it for new and running work.
          </p>
          <div class="settings-field">
            <label for="model-access-kind">Sign-in method</label>
            <select id="model-access-kind" name="kind" phx-change="kind" phx-target={@myself}>
              <option value="apikey" selected={@kind == "apikey"}>API key</option>
              <option value="transfer" selected={@kind == "transfer"}>
                Import from Coop
              </option>
            </select>
          </div>
          <form
            :if={@kind == "apikey"}
            id="model-key-form"
            class="settings-form"
            phx-submit="save-key"
            phx-target={@myself}
            autocomplete="off"
          >
            <div class="settings-field">
              <label for="model-access-secret">API key</label>
              <input
                id="model-access-secret"
                name="credential[secret]"
                type="password"
                autocomplete="new-password"
                required
              />
            </div>
            <Components.form_feedback
              :if={@error}
              id="model-access-error"
              message={@error}
              tone={:error}
            />
            <div class="settings-actions">
              <.link patch="/settings/models" class="ui-button">Cancel</.link>
              <button class="ui-button primary" type="submit" phx-disable-with="Saving…">Save access</button>
            </div>
          </form>
          <div :if={@kind == "transfer"} class="settings-form">
            <p class="settings-help">
              On the signed-in Coop, run <code>coop credentials {hd(String.split(@account, "@"))} &lt;account&gt; export</code>.
              Paste this installation’s receive code when prompted.
            </p>
            <p :if={String.starts_with?(@account, "claude@")} class="settings-help">
              Ryker accepts Anthropic API keys. Claude subscription logins can move between Coop installations.
            </p>
            <button
              :if={!@receive_code}
              type="button"
              class="ui-button"
              phx-click="receive-code"
              phx-target={@myself}
            >Get receive code</button>
            <div :if={@receive_code}>
              <button type="button" class="ui-button" data-copy-value={@receive_code}>
                Copy receive code<span class="sr-only" data-copy-status aria-live="polite"></span>
              </button>
              <details>
                <summary>Show code</summary>
                <pre class="model-receive-code" id="model-receive-code">{@receive_code}</pre>
              </details>
            </div>
            <form
              :if={@receive_code}
              id="model-transfer-form"
              class="settings-form"
              phx-submit="receive-bundle"
              phx-target={@myself}
            >
              <div class="settings-field">
                <label for="model-transfer-target">Save account as</label>
                <select id="model-transfer-target" name="target">
                  <option
                    :for={name <- @view.snapshot.work.model_accounts}
                    :if={hd(String.split(name, "@")) == hd(String.split(@account, "@"))}
                    value={name}
                    selected={name == @account}
                  >
                    {name}
                  </option>
                </select>
              </div>
              <div class="settings-field">
                <label for="model-transfer-bundle">Encrypted bundle from Coop</label>
                <textarea
                  id="model-transfer-bundle"
                  name="secret_bundle"
                  rows="4"
                  autocomplete="off"
                  spellcheck="false"
                  required
                ></textarea>
              </div>
              <div class="settings-actions">
                <button class="ui-button primary" type="submit" phx-disable-with="Importing…">Import account</button>
              </div>
            </form>
            <Components.form_feedback
              :if={@error}
              id="model-transfer-error"
              message={@error}
              tone={:error}
            />
          </div>
        </div>
      </Kit.form_card>
      <Kit.form_card :if={@capacity} label="Request concurrency">
        <form
          id="model-concurrency-form"
          class="settings-form"
          phx-submit="save-concurrency"
          phx-target={@myself}
        >
          <p class="settings-help">
            Maximum simultaneous inference requests across all workers using this account.
            Aliases of the same API key or native account share this limit. Set 0 to pause new requests.
            Requests already admitted can finish.
          </p>
          <div class="settings-field">
            <label for="model-concurrency">Concurrent requests</label>
            <input
              id="model-concurrency"
              name="concurrency"
              type="number"
              min="0"
              max="256"
              step="1"
              value={@capacity.concurrency}
              required
            />
          </div>
          <p class="settings-help">
            {@capacity.active} held requests · {@capacity.unresolved} awaiting controller stop confirmation
          </p>
          <p :if={@capacity.blocked_until} class="settings-notice">
            Provider cooldown until {DateTime.to_iso8601(@capacity.blocked_until)}.
          </p>
          <Components.form_feedback
            :if={@capacity_error}
            id="model-capacity-error"
            message={@capacity_error}
            tone={:error}
          />
          <div class="settings-actions">
            <button class="ui-button primary" type="submit" phx-disable-with="Saving…">Save concurrency</button>
          </div>
        </form>
      </Kit.form_card>
      <Kit.remove_card
        :if={@saved}
        id="model-access-remove"
        title="Remove account access"
        text="Running work loses this account's access. Models that select it will need new credentials."
        phx-click="ask-remove"
        phx-target={@myself}
      />
      <Kit.confirm_modal
        :if={@removing}
        id="remove-model-access"
        title={"Remove access for #{@account}?"}
        text="Running work loses this account's access, and future jobs need new credentials."
        label="Remove access"
        cancel="cancel-remove"
        target={@myself}
        phx-click="remove"
        phx-target={@myself}
        pending="Removing…"
        error={@error}
      />
    </div>
    """
  end

  # LiveView supplies the server-side temporary path. client_name is only an account-file label.
  # sobelow_skip ["Traversal.FileModule"]
end
