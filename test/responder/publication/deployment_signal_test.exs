defmodule Responder.Publication.DeploymentSignalTest do
  use ExUnit.Case, async: true

  alias Responder.Publication.DeploymentSignal

  test "accepts only the exact bounded lifecycle contract" do
    signal = %{
      "event_type" => "responder.publication_lifecycle.v1",
      "payload" => %{
        "environment" => "production",
        "kind" => "deployment",
        "references" => ["https://github.com/acme/responder/pull/91", String.duplicate("a", 40)],
        "repository" => "responder",
        "run_ref" => "deploy:provider:123",
        "state" => "succeeded",
        "target" => "responder-web"
      }
    }

    assert DeploymentSignal.prepare(signal) == {:ok, signal}

    assert DeploymentSignal.authorize(signal, %{
             "environments" => ["production"],
             "kinds" => ["deployment", "terraform"],
             "repositories" => ["responder"],
             "targets" => ["responder-web"]
           }) == :ok

    assert DeploymentSignal.authorize(
             signal,
             %{
               "environments" => ["staging"],
               "kinds" => ["deployment"],
               "repositories" => ["responder"],
               "targets" => ["responder-web"]
             }
           ) == {:error, :publication_lifecycle_source_unauthorized}

    assert {:error, {:invalid_publication_deployment_signal, :fields}} =
             DeploymentSignal.prepare(put_in(signal, ["extra"], true))

    assert {:error, {:invalid_publication_deployment_signal, :fields}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "extra"], true))

    assert {:error, {:invalid_publication_deployment_signal, :state}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "state"], "complete"))

    assert {:error, {:invalid_publication_deployment_signal, :references}} =
             DeploymentSignal.prepare(
               put_in(signal, ["payload", "references"], ["duplicate", "duplicate"])
             )

    assert {:error, {:invalid_publication_deployment_signal, :references}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "references"], []))

    assert {:error, {:invalid_publication_deployment_signal, :references}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "references"], [42]))

    assert {:error, {:invalid_publication_deployment_signal, :environment}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "environment"], " \t"))

    assert {:error, {:invalid_publication_deployment_signal, :run_ref}} =
             DeploymentSignal.prepare(put_in(signal, ["payload", "run_ref"], nil))

    assert {:error, {:invalid_publication_deployment_signal, :target}} =
             DeploymentSignal.prepare(
               put_in(signal, ["payload", "target"], String.duplicate("x", 1_025))
             )
  end
end
