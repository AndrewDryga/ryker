defmodule Ryker.CoopFleet.ServiceRelays do
  @moduledoc "Ten-minute operator access to one declared TCP port on an exact job-owned container."
  alias Ryker.CoopFleet.{Certificate, ControlPlane, ServiceConnections, Worker}
  alias Ryker.Operator
  alias Ryker.{Repo, Secret}

  @scope "ryker/fleet/service-relay/v1"
  @lifetime 600

  def issue(job, name, port, options) when is_integer(port) and port in 1..65_535 do
    with {:ok, job} <- Ecto.UUID.cast(job),
         {:ok, holder} <- Repo.fetch(Operator.FleetJob.Query.service_holder(job)),
         {:ok, worker} <- Repo.fetch(Worker.Query.by_id(holder.worker)),
         true <- Worker.advertises?(worker, "service-relay", "1"),
         {:ok, catalog} <- Operator.FleetJobs.services(job, options),
         true <-
           catalog.worker_id == holder.worker and
             catalog.placement_generation == holder.generation,
         %{"container_id" => id, "ports" => ports, "state" => "running"} <-
           Enum.find(catalog.services, &(&1["name"] == name)),
         true <- is_binary(id) and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) and port in ports do
      binding = %{
        holder: holder,
        name: name,
        container: id,
        port: port,
        expires: System.system_time(:second) + @lifetime,
        nonce: Ecto.UUID.generate()
      }

      key = options |> Keyword.fetch!(:checkpoint_key) |> Secret.reveal()

      {:ok,
       %{
         token: Plug.Crypto.sign(key, @scope, binding, max_age: @lifetime),
         expires: binding.expires
       }}
    else
      _refused -> {:error, :fleet_service_unavailable}
    end
  end

  def issue(_job, _name, _port, _options), do: {:error, :fleet_service_unavailable}

  def verify(token, options) do
    with %Secret{} = key <- options[:checkpoint_key],
         {:ok, binding} <-
           Plug.Crypto.verify(Secret.reveal(key), @scope, token, max_age: @lifetime),
         true <- current?(binding) do
      {:ok, binding}
    else
      _refused -> :error
    end
  end

  def current?(%{holder: holder, expires: expires}) do
    expires > System.system_time(:second) and
      Repo.fetch(Operator.FleetJob.Query.service_holder(holder.job)) == {:ok, holder}
  end

  def worker(id, cert) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         [{owner, binding}] <- Registry.lookup(ServiceConnections, {:operator, id}),
         hash = Ryker.Crypto.sha256_hex(cert),
         true <- authenticated?(binding, hash) do
      {:ok, {:worker, id, owner, binding, hash}}
    else
      _refused -> :error
    end
  end

  def authenticated?(%{holder: holder} = binding, hash) do
    Repo.fetch(Certificate.Query.active_worker_binding(hash)) ==
      {:ok, {holder.worker, holder.epoch}} and current?(binding)
  end

  def connect(id, binding) do
    holder = binding.holder

    request = %{
      "method" => "POST",
      "path" =>
        "/v1/sessions/" <>
          URI.encode(holder.remote, &URI.char_unreserved?/1) <>
          "/services/" <> URI.encode(binding.name, &URI.char_unreserved?/1) <> "/connections",
      "body" => %{
        "connection" => id,
        "container" => binding.container,
        "job_digest" => holder.digest,
        "port" => binding.port,
        "expires" => binding.expires
      }
    }

    ControlPlane.enqueue_command(
      holder.placement,
      "api_request",
      request,
      "fleet-service-connection:" <> id
    )
  end
end
