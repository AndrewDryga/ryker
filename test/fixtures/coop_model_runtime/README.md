# Two-worker fleet acceptance

Run this from the Ryker checkout with a local Docker engine, Go, OpenSSL, the project Elixir
toolchain and seven Docker CPUs available. Use a Linux Coop binary and its matching worker,
client and network guard images. The worker image runs the connector. The client image provides
the base for the scripted ACP clients. All images must already be in the selected local engine,
including the PostgreSQL and Docker-in-Docker digests listed in the script.

```sh
bash test/fixtures/coop_model_runtime/run.sh /absolute/path/to/linux-coop "$worker_image" "$clients_image" "$guard_image"
```

The test enrolls two workers, holds an inference request on each, verifies where each job ran,
reads both results, closes the sessions and checks that capacity returns. It also exercises
certificate rotation, HTTP and WebSocket proxy traffic, account revocation and worker credential
custody. Set `RYKER_FLEET_LONG_STREAM=1` to exercise 125 seconds of provider silence followed
by a separate 70-second trickle stream. Provider requests use synthetic responses. The harness
creates disposable Docker engines, volumes, a test image and a database, and cleans them up on exit.
