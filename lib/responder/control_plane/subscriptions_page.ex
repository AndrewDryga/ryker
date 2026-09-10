defmodule Responder.ControlPlane.SubscriptionsPage do
  @moduledoc false
  use Phoenix.Component

  alias Responder.ControlPlane.SubscriptionPresentation, as: Presentation

  def render(assigns) do
    assigns = assign_new(assigns, :now, &DateTime.utc_now/0)

    ~H"""
    <section class="subscriptions-view" aria-label="Waits">
      <p class="subscription-window">
        Showing up to 100 waits in the selected status, with active waits first. Search filters this list. Exact subscription references search all history within that status.
      </p>
      <p :if={@items == []} class="empty-state">No waits match these filters.</p>
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
            <span class={"ui-status status-#{tone}"}><i aria-hidden="true"></i>{label}</span>
            <dl>
              <div :for={{label, text, at} <- Presentation.timing(item, @now)}>
                <dt>{label}</dt>
                <dd>
                  <time
                    :if={at}
                    id={"wait-time-#{item.ref}-#{URI.encode_www_form(label)}"}
                    datetime={exact(at)}
                    title={exact(at)}
                    aria-label={"#{text} · #{Calendar.strftime(at, "%d %b %Y, %H:%M UTC")}"}
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
    </section>
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
