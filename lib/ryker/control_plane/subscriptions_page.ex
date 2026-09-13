defmodule Ryker.ControlPlane.SubscriptionsPage do
  @moduledoc false
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [status: 1, timestamp: 1]
  alias Ryker.ControlPlane.SubscriptionPresentation, as: Presentation

  # The rows only; the window and search semantics live in the page help, and
  # the shell renders the title, description, toolbar and count around this.
  # `filtered` says whether the toolbar is narrowing the list, which decides
  # what an empty list means.
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:filtered, fn -> false end)
      |> assign_new(:now, &DateTime.utc_now/0)

    ~H"""
    <div class="subscriptions-view" role="region" aria-label="Waits">
      <p :if={@items == []} class="empty-state">
        {if @filtered,
          do: "No waits match these filters.",
          else:
            "No waits right now. Work that pauses for a timer or an external event appears here while it waits."}
      </p>
      <div :if={@items != []} class="subscription-list">
        <article :for={item <- @items} class="subscription-row" id={"wait-#{item.ref}"}>
          <div class="subscription-purpose">
            <h2 class="subscription-title">{item.title}</h2>
            <p class="subscription-condition">{item.condition}</p>
            <p class="subscription-request">
              <a :if={item.episode_href} href={item.episode_href} id={"wait-request-#{item.ref}"}>{item.episode_title}</a>
              <span :if={!item.episode_href}>{item.episode_title}</span>
            </p>
            <p class="subscription-context">{item.context_label}</p>
            <a
              :if={item.target_url}
              class="subscription-target"
              id={"wait-target-#{item.ref}"}
              href={item.target_url}
              rel="noreferrer"
              aria-label={"Open target for #{item.title}"}
            >Open target →</a>
          </div>
          <div class="subscription-timing">
            <% {label, tone} = Presentation.status(item) %>
            <.status label={label} tone={tone} />
            <dl>
              <div :for={{label, text, at} <- Presentation.timing(item, @now)}>
                <dt>{label}</dt>
                <dd>
                  <time
                    :if={at}
                    id={"wait-time-#{item.ref}-#{URI.encode_www_form(label)}"}
                    datetime={exact(at)}
                    title={exact(at)}
                    aria-label={"#{text} · #{timestamp(at)}"}
                    tabindex="0"
                  >{text}</time>
                  <span :if={!at}>{text}</span>
                </dd>
              </div>
            </dl>
          </div>
          <details class="subscription-details" id={"wait-details-#{item.ref}"}>
            <summary
              id={"wait-summary-#{item.ref}"}
              aria-label={"Technical details for #{item.title}"}
            >
              Technical details
            </summary>
            <dl>
              <div :for={{label, value} <- details(item)}>
                <dt>{label}</dt><dd>{value || "Not recorded"}</dd>
              </div>
            </dl>
          </details>
        </article>
      </div>
    </div>
    """
  end

  defp details(item) do
    [
      {"Subscription", item.ref},
      {"Episode", item.episode_ref},
      {"Source", item.source_kind},
      {"Revision", item.revision},
      {"Matcher digest", item.matcher_digest},
      {"Cursor digest", item.cursor_digest},
      {"Observation digest", item.last_observation_digest},
      {"Next wake-up (UTC)", exact(item.poll_after)},
      {"Deadline (UTC)", exact(item.deadline_at)},
      {"Observed (UTC)", exact(item.last_observed_at)},
      {"Updated (UTC)", exact(item.updated_at)}
    ]
  end

  defp exact(nil), do: nil
  defp exact(at), do: DateTime.to_iso8601(at)
end
