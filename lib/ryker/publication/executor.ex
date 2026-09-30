defmodule Ryker.Publication.Executor do
  @moduledoc """
  Executes one leased publication phase without owning routing or authority.

  Review, notification, and publication are separate durable phases. Every
  retry reuses the frozen Coop review key/revision or the exact retained commit;
  an operator approval can therefore never drift to a newer workspace tree.
  """

  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Delivery.Adapters
  alias Ryker.LeasedCall
  alias Ryker.Publication.{Custody, FixLoop, GateOutput, Request}
  alias Ryker.Slack.TaskCards
  alias Ryker.Work.Session

  @review_states ~w(open exhausted)
  @closed_session_states ~w(closed discarded)

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%{lease_ref: lease_ref, publication: publication, session: _session} = claim, options)
      when is_binary(lease_ref) and is_list(options) do
    with {:ok, settings} <- settings(options) do
      case publication.status do
        :review_pending -> review(claim, settings)
        :review_ready -> deliver(claim, settings)
        :publish_pending -> publish(claim, settings)
        :published_ready -> deliver(claim, settings)
        _other -> {:error, :publication_not_executable}
      end
    end
  end

  def run(_claim, _options), do: {:error, {:invalid_publication_executor, :claim}}

  defp review(claim, settings) do
    publication = claim.publication
    session = claim.session

    with :ok <- review_session_open(session),
         {:ok, remote} <-
           leased_call(claim, settings, fn ->
             settings.api.get_session(settings.client, session.coop_session_id)
           end),
         {:ok, revision} <- exact_review_session(remote, session),
         {:ok, frozen} <-
           settings.custody.freeze_review_revision(publication.ref, claim.lease_ref, revision),
         key <- review_key(frozen),
         {:ok, response} <- run_review(claim, frozen, key, settings),
         {:ok, dossier} <- exact_review_response(response, session.coop_session_id),
         {:ok, stored} <-
           settings.custody.store_review(
             publication.ref,
             claim.lease_ref,
             frozen.review_generation,
             dossier,
             gate_output(claim, frozen, dossier, settings)
           ) do
      {:ok, %{phase: review_phase(stored), publication: stored}}
    end
  end

  # The whole output of a gate the task's work will be asked to fix, read while
  # the review is still fresh. Best effort: a read that fails leaves the fix
  # round telling the agent to run the gate itself, and never fails the review.
  defp gate_output(claim, frozen, dossier, settings) do
    if FixLoop.gate_output_wanted?(frozen, claim.session, dossier),
      do: read_gate_output(claim, frozen, dossier, settings)
  end

  defp read_gate_output(claim, frozen, dossier, settings) do
    read = fn -> {:ok, GateOutput.capture(settings.api, settings.client, frozen, dossier)} end

    case leased_call(claim, settings, read) do
      {:ok, output} -> output
      {:error, _reason} -> nil
    end
  end

  # A refusal that only says something moved during the check is asked again
  # (`Ryker.Publication.FixLoop`), so custody hands back a fresh pending review.
  defp review_phase(%{status: :review_pending}), do: :rechecking
  defp review_phase(_stored), do: :reviewed

  defp deliver(claim, settings) do
    with {:ok, request} <- settings.custody.delivery_request(claim.publication),
         {:ok, receipt} <- deliver_request(claim, request, settings),
         {:ok, stored} <-
           settings.custody.confirm_delivery(
             claim.publication.ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok, %{phase: :delivered, publication: stored, receipt: receipt}}
    end
  end

  # A publication whose task has a card in its thread is delivered by that
  # card (`Ryker.Slack.TaskCards.card_receipt/2`); nothing new is posted.
  defp deliver_request(claim, request, settings) do
    case TaskCards.card_receipt(claim.publication.episode_id, request) do
      nil -> leased_call(claim, settings, fn -> Adapters.publish(request, settings.adapters) end)
      settled -> settled
    end
  end

  defp publish(claim, settings) do
    with {:ok, request} <- Request.new(claim.publication),
         {:ok, body} <- Request.worker_body(request, settings.repositories),
         result <-
           leased_call(claim, settings, fn ->
             settings.api.publish_review(
               settings.client,
               claim.session.coop_session_id,
               review_key(claim.publication),
               request.review["operation_id"],
               publish_key(claim.publication),
               body
             )
           end) do
      store_publish_result(result, claim, settings)
    end
  end

  defp store_publish_result({:ok, receipt}, claim, settings) do
    with {:ok, stored} <-
           settings.custody.store_publication(
             claim.publication.ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok, %{phase: :published, publication: stored, receipt: receipt}}
    end
  end

  defp store_publish_result(
         {:error, {:publication_conflict, code, receipt} = reason},
         claim,
         settings
       ) do
    with {:ok, _stored} <-
           settings.custody.store_conflict(
             claim.publication.ref,
             claim.lease_ref,
             code,
             receipt
           ) do
      {:error, reason}
    end
  end

  defp store_publish_result({:error, _reason} = error, _claim, _settings), do: error

  # Ryker records the close itself when it cleans a session up, and a closed
  # Coop session never reopens: asking the worker about it again would only
  # spend a command to learn what is already on record here.
  defp review_session_open(%Session{discarded_at: %DateTime{}}),
    do: {:error, {:publication_review_session_closed, "discarded"}}

  defp review_session_open(%Session{closed_at: %DateTime{}}),
    do: {:error, {:publication_review_session_closed, "closed"}}

  defp review_session_open(_session), do: :ok

  # A closed or discarded session is an answer, not a protocol error: the
  # review can never run there, and the dispatcher ends the publication on it.
  defp exact_review_session(
         %{
           "external_ref" => _external_ref,
           "id" => _id,
           "job_ref" => _job_ref,
           "job_digest" => _digest,
           "revision" => revision,
           "state" => state
         } = remote,
         session
       ) do
    cond do
      not same_review_session?(remote, session) ->
        {:error, {:publication_coop_identity_mismatch, :session}}

      state in @closed_session_states ->
        {:error, {:publication_review_session_closed, state}}

      state in @review_states and is_integer(revision) and revision > 0 ->
        {:ok, revision}

      true ->
        {:error, {:publication_coop_protocol_error, :session}}
    end
  end

  defp exact_review_session(_remote, _session),
    do: {:error, {:publication_coop_protocol_error, :session}}

  defp same_review_session?(remote, session) do
    remote["id"] == session.coop_session_id and
      JobAuthority.exact_receipt(session, remote) == :ok
  end

  defp exact_review_response(
         %{
           "operation" => %{
             "id" => operation_id,
             "method" => "RunReview",
             "resource_id" => session_id,
             "resource_type" => "review",
             "state" => "succeeded"
           },
           "review" => %{"operation_id" => operation_id, "session_id" => session_id} = review
         },
         session_id
       )
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, review}

  defp exact_review_response(_response, _session_id),
    do: {:error, {:publication_coop_protocol_error, :review}}

  defp run_review(claim, frozen, key, settings) do
    result =
      leased_call(claim, settings, fn ->
        settings.api.run_review(
          settings.client,
          claim.session.coop_session_id,
          key,
          frozen.review_expected_revision
        )
      end)

    case result do
      {:error, {:coop_error, 409, "revision_conflict", _detail} = reason} ->
        spend_review_generation(claim, frozen, reason, settings)

      # The worker restarted under the review and it will never finish (30 Sep, OrbStack).
      {:error, {:coop_review_lost, _detail} = reason} ->
        spend_review_generation(claim, frozen, reason, settings)

      other ->
        other
    end
  end

  # The next attempt reviews the same change again under a new key.
  defp spend_review_generation(claim, frozen, reason, settings) do
    case settings.custody.advance_review_generation(
           claim.publication.ref,
           claim.lease_ref,
           frozen.review_generation
         ) do
      {:ok, _publication} -> {:error, {:publication_review_generation_spent, reason}}
      {:error, _reason} = error -> error
    end
  end

  def review_key(publication) do
    "ryker:publication:review:#{publication.id}:g#{publication.review_generation}"
  end

  def publish_key(publication) do
    "ryker:publication:publish:#{publication.id}:g#{publication.review_generation}"
  end

  defp leased_call(claim, settings, function) do
    LeasedCall.run(
      fn -> contained(function) end,
      fn ->
        settings.custody.renew(claim.publication.ref, claim.lease_ref, settings.lease_seconds)
      end,
      settings.lease_seconds,
      :publication_callback_exit
    )
  end

  defp contained(function) do
    function.()
  rescue
    exception -> {:error, {:publication_callback_crashed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:publication_callback_crashed, kind, reason}}
  end

  defp settings(options) do
    allowed = [
      :adapters,
      :api,
      :client,
      :custody,
      :lease_seconds,
      :repositories
    ]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [] do
      validate_settings(%{
        adapters: Keyword.fetch!(options, :adapters),
        api: Keyword.fetch!(options, :api),
        client: Keyword.fetch!(options, :client),
        custody: Keyword.get(options, :custody, Custody),
        lease_seconds: Keyword.get(options, :lease_seconds, 60),
        repositories: Keyword.fetch!(options, :repositories)
      })
    else
      {:error, {:invalid_publication_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_publication_executor, :options}}
  end

  defp validate_settings(settings) do
    callbacks = [
      {settings.api, [get_session: 2, publish_review: 6, run_review: 4], :api},
      {
        settings.custody,
        [
          confirm_delivery: 3,
          delivery_request: 1,
          advance_review_generation: 3,
          freeze_review_revision: 3,
          renew: 3,
          store_publication: 3,
          store_review: 5
        ],
        :custody
      }
    ]

    with :ok <- validate_callbacks(callbacks),
         true <- is_map(settings.adapters) and map_size(settings.adapters) > 0,
         true <- is_integer(settings.lease_seconds) and settings.lease_seconds > 0 do
      {:ok, settings}
    else
      false -> {:error, {:invalid_publication_executor, :settings}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_callbacks(callbacks) do
    Enum.reduce_while(callbacks, :ok, fn {module, functions, field}, :ok ->
      valid =
        is_atom(module) and Code.ensure_loaded?(module) and
          Enum.all?(functions, fn {function, arity} ->
            function_exported?(module, function, arity)
          end)

      if valid,
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_publication_executor, field}}}
    end)
  end
end
