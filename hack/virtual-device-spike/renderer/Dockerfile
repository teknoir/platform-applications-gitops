# vdev-spike-render: the S1 spike's cloud-init renderer, run as a Job by
# charts/virtual-device-spike (main.go -in-cluster). Standard library plus the pinned
# github.com/teknoir/cli pkg/templates. Build context: this directory.
#
#   docker build --build-arg CLI_REF="$VDS_CLI_REF" -t vdev-spike-render .
#
# CLI_REF has no default so that lib/pins.sh stays the only place that pins it; the
# workflow .github/workflows/vdev-spike-render.yaml reads it from there.

FROM golang:1.25.9-bookworm@sha256:298734aec230b5f3e8cee450ce6d7eccc39f1797ba548ee90d57e9803030c6c3 AS build
ARG CLI_REPO=https://github.com/teknoir/cli.git
ARG CLI_REF
RUN test -n "$CLI_REF" || { echo "CLI_REF build arg is required (VDS_CLI_REF in lib/pins.sh)" >&2; exit 1; }
WORKDIR /src
# Only the module files and pkg/templates of the pinned cli commit, as render.sh does.
RUN git init -q cli \
 && git -C cli fetch -q --depth 1 "$CLI_REPO" "$CLI_REF" \
 && test "$(git -C cli rev-parse FETCH_HEAD)" = "$CLI_REF" \
 && mkdir -p mod/cmd/vdev-spike-render \
 && git -C cli archive FETCH_HEAD go.mod go.sum pkg/templates | tar -x -C mod \
 && grep -qx 'module teknoir/cli' mod/go.mod
COPY main.go userdata.tmpl mod/cmd/vdev-spike-render/
WORKDIR /src/mod
RUN GOWORK=off GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' \
      -o /out/vdev-spike-render ./cmd/vdev-spike-render

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/vdev-spike-render /vdev-spike-render
USER 65532:65532
ENTRYPOINT ["/vdev-spike-render"]
