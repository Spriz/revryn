# Billing Core — single official OCI image (SPEC §24.6, INV-020).
#
# One image serves every role through the entrypoint:
#   billing-core all-in-one | web | worker | migrate | backup | restore |
#   smoke-test | doctor
#
# The all-in-one profile supervises PostgreSQL and the Phoenix release in one
# container with a single persistent volume root (/data).

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.3-erlang-29.0.5-debian-bookworm-20260803
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod LANG=C.UTF-8

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git curl ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets
# Compile first: Phoenix colocated assets are emitted during compilation and
# consumed by the Tailwind build.
RUN mix compile && mix assets.setup && mix assets.deploy

COPY rel rel
RUN mix release

FROM ${RUNTIME_IMAGE} AS runtime

ENV LANG=C.UTF-8 \
    HOME=/app \
    DATA_DIR=/data \
    PGDATA=/data/postgres

# Runtime deps: openssl/ncurses for the BEAM, PostgreSQL for the all-in-one
# profile, gosu for privilege drop, curl for health probes.
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates curl gosu \
      postgresql postgresql-client && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    sed -i '/C.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

RUN useradd --create-home --shell /bin/false app

WORKDIR /app

COPY --from=build --chown=app:app /app/_build/prod/rel/billing_core ./
COPY deploy/container/entrypoint.sh /usr/local/bin/billing-core
COPY scripts/backup /usr/local/bin/billing-core-backup
COPY scripts/restore /usr/local/bin/billing-core-restore
COPY scripts/restore-verify /usr/local/bin/billing-core-restore-verify
RUN chmod +x /usr/local/bin/billing-core /usr/local/bin/billing-core-backup \
      /usr/local/bin/billing-core-restore /usr/local/bin/billing-core-restore-verify && \
    mkdir -p /data && chown app:app /data

VOLUME ["/data"]
EXPOSE 4000

ENTRYPOINT ["billing-core"]
CMD ["all-in-one"]
