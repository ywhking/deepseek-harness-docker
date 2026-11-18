# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=docker.io/library/node:24-trixie
FROM ${NODE_IMAGE} AS installer

ARG DSH_VERSION=0.2.2-rc.3
ARG DSH_SUPERPOWERS_VERSION=0.5.0
ARG DSH_IM_GATEWAY_VERSION=0.3.5
ARG PNPM_VERSION=10.15.1

# Downloads dominate the first build, and every rebuild that invalidates a
# package layer pays them again. Both knobs default to the upstream endpoints,
# so an unchanged build behaves exactly as before; point them at a closer mirror
# to cut the wall clock (mainland China: DEBIAN_MIRROR=mirrors.aliyun.com and
# NPM_REGISTRY=https://registry.npmmirror.com). The BuildKit cache mounts keep
# downloaded .debs and npm tarballs in the builder cache rather than in the
# image, so a repeated build re-resolves instead of re-downloading.
ARG DEBIAN_MIRROR=deb.debian.org
ARG NPM_REGISTRY=https://registry.npmjs.org/
# apt retries and IPv4 forcing. Set APT_FORCE_IPV4=1 when the host has a broken
# IPv6 route (a common cause of apt crawling instead of failing over).
ARG APT_FORCE_IPV4=0

# node-pty publishes prebuilds for only some Linux architectures. Keep the
# installer requirements explicit so linux/arm64 can fall back to node-gyp,
# even if a maintainer experiments with another NODE_IMAGE. The default
# non-slim runtime separately retains its development toolchain on purpose.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,target=/root/.npm \
    set -eux; \
    mirror="${DEBIAN_MIRROR%/}"; \
    case "${mirror}" in \
      http://*|https://*) ;; \
      *) mirror="https://${mirror}" ;; \
    esac; \
    sed -i "s|https\?://deb.debian.org|${mirror}|g" /etc/apt/sources.list.d/debian.sources; \
    apt_opts="-o Acquire::Languages=none -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"; \
    if [ "${APT_FORCE_IPV4}" = "1" ]; then \
      apt_opts="${apt_opts} -o Acquire::ForceIPv4=true"; \
    fi; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get ${apt_opts} update; \
    apt-get ${apt_opts} install --yes --no-install-recommends \
      build-essential \
      ca-certificates \
      python3; \
    npm install --global --omit=dev --no-audit --no-fund \
      --registry="${NPM_REGISTRY}" \
      --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
      "pnpm@${PNPM_VERSION}"; \
    test "$(dsh --version)" = "${DSH_VERSION}"; \
    test "$(pnpm --version)" = "${PNPM_VERSION}"

# Browser Use, Superpowers and the IM gateway are all installed outside DSH's
# package prefix: adding packages directly into the published DSH tree can make
# npm prune packages that are part of DSH's generated distribution. Each bundle
# lives in its own isolated tree that is merged (or linked) into the runtime
# image only after DSH itself has been copied. The three installs are
# independent, so they run in parallel here to cut the installer stage's wall
# clock; the shared npm cache mount is locked so concurrent resolvers cannot
# race each other. Job failures are collected through `wait ... || fail=1` and
# surfaced with `exit "$fail"`: `wait a && wait b` would silently ignore a
# failed `a` under `set -e`.
#
# - Browser Use: the Playwright MCP provider for the browser desktop.
# - Superpowers: community skills (TDD, systematic debugging, planning, code
#   review) with no runtime dependencies; its 15 skill bodies ship in-package.
# - IM gateway: chat assistant on DingTalk/QQ/WeChat/Feishu/WeCom. Unlike
#   Superpowers it carries runtime dependencies (qrcode, ws, per-platform SDKs),
#   so its whole tree ships with the image; the @deepseek-ai peers it imports
#   stay in DSH and are linked in the runtime stage. The @lijian-ui fork is
#   pinned because upstream dsh-im-gateway@0.3.3 declares a peer range
#   (^0.1.0-rc.6) that DSH 0.2.2-rc.3 rejects, while the fork declares
#   >=0.1.0 <0.3.0-0. Switch the package only with a DSH version whose range it
#   declares.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    set -eux; \
    ( mkdir -p /opt/dsh-browser-use \
      && npm install \
        --prefix /opt/dsh-browser-use \
        --registry="${NPM_REGISTRY}" \
        --package-lock=false --omit=dev --no-audit --no-fund --ignore-scripts --legacy-peer-deps \
        "@deepseek-ai/dsh-browser-use@${DSH_VERSION}" \
        "@deepseek-ai/dsh-experimental-browser-use-playwright-mcp@${DSH_VERSION}" \
      && test "$(node -p 'require("/opt/dsh-browser-use/node_modules/@deepseek-ai/dsh-browser-use/package.json").version')" = "${DSH_VERSION}" \
      && test "$(node -p 'require("/opt/dsh-browser-use/node_modules/@deepseek-ai/dsh-experimental-browser-use-playwright-mcp/package.json").version')" = "${DSH_VERSION}" \
    ) & p1=$!; \
    ( mkdir -p /opt/dsh-superpowers \
      && npm install \
        --prefix /opt/dsh-superpowers \
        --registry="${NPM_REGISTRY}" \
        --package-lock=false --omit=dev --no-audit --no-fund --ignore-scripts --legacy-peer-deps \
        "superpowers-dsh@${DSH_SUPERPOWERS_VERSION}" \
      && test "$(node -p 'require("/opt/dsh-superpowers/node_modules/superpowers-dsh/package.json").version')" = "${DSH_SUPERPOWERS_VERSION}" \
      && test "$(find /opt/dsh-superpowers/node_modules/superpowers-dsh/skills -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 15 \
    ) & p2=$!; \
    ( mkdir -p /opt/dsh-im-gateway \
      && npm install \
        --prefix /opt/dsh-im-gateway \
        --registry="${NPM_REGISTRY}" \
        --package-lock=false --omit=dev --no-audit --no-fund --ignore-scripts --legacy-peer-deps \
        "@lijian-ui/dsh-im-gateway@${DSH_IM_GATEWAY_VERSION}" \
      && test "$(node -p 'require("/opt/dsh-im-gateway/node_modules/@lijian-ui/dsh-im-gateway/package.json").version')" = "${DSH_IM_GATEWAY_VERSION}" \
      && test -f /opt/dsh-im-gateway/node_modules/@lijian-ui/dsh-im-gateway/lib/client.js \
      && test -f /opt/dsh-im-gateway/node_modules/@lijian-ui/dsh-im-gateway/cordis.patch.yml \
    ) & p3=$!; \
    fail=0; \
    wait "$p1" || fail=1; \
    wait "$p2" || fail=1; \
    wait "$p3" || fail=1; \
    exit "$fail"

FROM ${NODE_IMAGE}

ARG NODE_IMAGE
ARG DSH_VERSION=0.2.2-rc.3
ARG DSH_SUPERPOWERS_VERSION=0.5.0
ARG DSH_IM_GATEWAY_VERSION=0.3.5
ARG PNPM_VERSION=10.15.1
ARG CHROMIUM_FLAVOR=debian
ARG UNGOOGLED_CHROMIUM_VERSION=152.0.7977.82-1
ARG UNGOOGLED_CHROMIUM_AMD64_SHA256=2c6e464e030f87145e42553c5aa539f6e62163ce677d3eace3c51b4fcbd5e347
ARG UNGOOGLED_CHROMIUM_ARM64_SHA256=1909f42dcc3661bc213f2cf3b5232a9d3c850913b36efa7267ed6499f6cbf87d
ARG TARGETARCH

# Same mirror switch as the installer stage: the runtime layer downloads the
# Debian toolchain, the Noto CJK fonts and Chromium itself. The mirror switch
# and download options are applied once here and shared by every apt-using
# layer below, so the big font/Chromium downloads are not coupled to the
# frequently-edited CLI tool list.
ARG DEBIAN_MIRROR=deb.debian.org

RUN set -eux; \
    mirror="${DEBIAN_MIRROR%/}"; \
    case "${mirror}" in \
      http://*|https://*) ;; \
      *) mirror="https://${mirror}" ;; \
    esac; \
    sed -i "s|https\?://deb.debian.org|${mirror}|g" /etc/apt/sources.list.d/debian.sources; \
    printf '%s\n' \
      'Acquire::Languages "none";' \
      'Acquire::Retries "5";' \
      'Acquire::http::Timeout "30";' \
      'Acquire::https::Timeout "30";' \
      > /etc/apt/apt.conf.d/99dsh

# Use Node's official non-slim Trixie variant intentionally: its buildpack-deps
# base provides the compiler and common development utilities a coding agent or
# native plugin may need at runtime, while glibc 2.41 accepts newer binaries
# than Bookworm's glibc 2.36. Install the remaining user-facing CLI tools
# explicitly so their availability is covered by the smoke test. The default
# flavor installs Chromium from Debian. The separately tagged ungoogled flavor
# uses a checksum-pinned portable build and still runs natively on amd64/arm64.
# The large Noto CJK fonts and Chromium live in the next layer, separate from
# this list, so editing the tools below reuses the cached font/Chromium layer.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    case "${CHROMIUM_FLAVOR}" in \
      debian|ungoogled) ;; \
      *) echo "unsupported Chromium flavor: ${CHROMIUM_FLAVOR}" >&2; exit 1 ;; \
    esac; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      ca-certificates \
      curl \
      file \
      git \
      jq \
      less \
      openbox \
      openssh-client \
      procps \
      python3 \
      ripgrep \
      rsync \
      tini \
      unzip \
      websockify \
      wget \
      x11-utils \
      x11vnc \
      xterm \
      xvfb \
      zip; \
    mkdir -p /usr/local/lib/node_modules/@deepseek-ai

# Chromium and the Noto CJK fonts are the two largest downloads of this image,
# so they share one layer: editing the CLI tool list above reuses the cached
# browser and fonts, and a rebuilt layer re-installs from the apt archive cache
# instead of the network. The ungoogled flavor keeps a checksum-pinned portable
# browser download while the fonts still come from apt.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      fonts-liberation \
      fonts-noto-cjk; \
    if [ "${CHROMIUM_FLAVOR}" = debian ]; then \
      apt-get install --yes --no-install-recommends chromium; \
    else \
      case "${TARGETARCH}" in \
        amd64) \
          ungoogled_arch=x86_64; \
          ungoogled_sha256="${UNGOOGLED_CHROMIUM_AMD64_SHA256}"; \
          ;; \
        arm64) \
          ungoogled_arch=arm64; \
          ungoogled_sha256="${UNGOOGLED_CHROMIUM_ARM64_SHA256}"; \
          ;; \
        *) echo "unsupported architecture for ungoogled-chromium: ${TARGETARCH}" >&2; exit 1 ;; \
      esac; \
      ungoogled_archive="ungoogled-chromium-${UNGOOGLED_CHROMIUM_VERSION}-${ungoogled_arch}_linux.tar.xz"; \
      ungoogled_url="https://github.com/ungoogled-software/ungoogled-chromium-portablelinux/releases/download/${UNGOOGLED_CHROMIUM_VERSION}/${ungoogled_archive}"; \
      curl --fail --location --retry 3 --output "/tmp/${ungoogled_archive}" "${ungoogled_url}"; \
      printf '%s  %s\n' "${ungoogled_sha256}" "/tmp/${ungoogled_archive}" | sha256sum --check --strict -; \
      mkdir -p /opt/ungoogled-chromium; \
      tar --extract --xz --file "/tmp/${ungoogled_archive}" \
        --directory /opt/ungoogled-chromium --strip-components=1; \
      ln -s /opt/ungoogled-chromium/chrome-wrapper /usr/bin/chromium; \
      rm -f "/tmp/${ungoogled_archive}"; \
    fi

# The portable archive contains Chromium itself, but intentionally does not
# bundle the Debian shared libraries it links against. Keep these packages in
# a separate layer so changing the dependency set does not invalidate the much
# larger, checksum-verified browser download above.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    if [ "${CHROMIUM_FLAVOR}" = ungoogled ]; then \
      apt-get update; \
      apt-get install --yes --no-install-recommends \
        libasound2t64 \
        libatk-bridge2.0-0t64 \
        libatk1.0-0t64 \
        libatspi2.0-0t64 \
        libcairo2 \
        libdav1d7 \
        libdouble-conversion3 \
        libflac14 \
        libglib2.0-0t64 \
        libharfbuzz-subset0 \
        libharfbuzz0b \
        libjpeg62-turbo \
        liblcms2-2 \
        libminizip1t64 \
        libmp3lame0 \
        libmpg123-0t64 \
        libnspr4 \
        libnss3 \
        libogg0 \
        libopenh264-8 \
        libopenjp2-7 \
        libopus0 \
        libpango-1.0-0 \
        libpulse0 \
        libvorbis0a \
        libvorbisenc2 \
        libx11-6 \
        libxcb1 \
        libxext6 \
        libxkbcommon0 \
        libxnvctrl0; \
      ! ldd /opt/ungoogled-chromium/chrome | grep -F 'not found'; \
    fi

# noVNC is fetched from the Debian archive and unpacked by hand rather than
# installed as a package: the `novnc` package pulls in the Debian `nodejs`
# runtime (libnode), but this image only serves noVNC's static files through
# Python websockify and the Node relay, so the duplicate Node runtime is dead
# weight. Keep the distro-provided root for backward-compatible direct links,
# while giving the embedded client an immutable path; this prevents a browser
# from combining an upgraded rfb.js with an older cached util/browser.js.
ARG NOVNC_ASSET_REVISION=debian-1.6.0-2
RUN --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    cd /tmp; \
    apt-get download novnc; \
    mkdir -p /tmp/novnc-extract /usr/share/novnc; \
    dpkg-deb --extract novnc_*.deb /tmp/novnc-extract; \
    cp -a /tmp/novnc-extract/usr/share/novnc/. /usr/share/novnc/; \
    rm -rf /tmp/novnc-extract novnc_*.deb; \
    novnc_copy="$(mktemp -d)"; \
    cp -a /usr/share/novnc/. "${novnc_copy}/"; \
    mkdir -p "/usr/share/novnc/novnc-${NOVNC_ASSET_REVISION}"; \
    cp -a "${novnc_copy}/." "/usr/share/novnc/novnc-${NOVNC_ASSET_REVISION}/"; \
    rm -rf "${novnc_copy}"

# dsh misdetects Docker Desktop's WSL2 kernel as WSL and spawns
# wslpath/powershell.exe (absent in the container) to open native paths.
# Fake wslpath echoes the target path; fake powershell.exe hands it to wish
# on the VNC display (:99, viewable through noVNC), so "Open configuration
# file" and host.openPath open the editor instead of failing with ENOENT.
RUN cat > /usr/local/bin/wslpath <<'SHIM'
#!/bin/sh
# Fake wslpath: dsh calls `wslpath -w <path>`; echo the path unchanged.
out=""
for arg in "$@"; do
  case "$arg" in
    -w|-u|-m|--*) ;;
    *) out="$arg" ;;
  esac
done
printf '%s\n' "${out:-/}"
exit 0
SHIM
RUN cat > /usr/local/bin/powershell.exe <<'SHIM'
#!/bin/sh
# Fake powershell.exe: dsh runs
#   powershell.exe -NoProfile -Command "Invoke-Item -LiteralPath '<path>'"
# Extract the path and open it with wish on the VNC desktop, then exit 0 so
# dsh reports the open as successful.
command_text=""
for arg in "$@"; do
  case "$arg" in
    -NoProfile|-Command) ;;
    *) command_text="$arg" ;;
  esac
done
path=""
if [ -n "$command_text" ]; then
  path=$(printf '%s' "$command_text" \
    | sed -n "s/.*-LiteralPath[[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" \
    | sed "s/''/'/g")
fi
if [ -z "$path" ] || [ ! -e "$path" ]; then exit 0; fi
DISPLAY="${DISPLAY:-:99}" /usr/bin/wish /usr/local/bin/dsh-editor.tcl "$path" >/dev/null 2>&1 &
exit 0
SHIM
RUN cat > /usr/local/bin/dsh-editor.tcl <<'SHIM'
#!/usr/bin/wish
# VNC desktop mini editor, opened by the fake powershell.exe above.
# File mode: edit and Save (Ctrl+S). Directory mode: double-click to descend.
set target [lindex $argv 0]
if {$target eq ""} { exit }

if {[file isdirectory $target]} {
  wm title . "Pick: $target"
  wm geometry . 680x520
  listbox .lb -width 90 -height 30 -yscrollcommand {.vs set}
  scrollbar .vs -command {.lb yview}
  pack .lb -side left -fill both -expand true
  pack .vs -side right -fill y
  foreach f [lsort [glob -nocomplain -directory $target *]] {
    .lb insert end [file tail $f]
  }
  bind .lb <Double-Button-1> {
    set sel [lindex [.lb curselection] 0]
    if {$sel ne ""} {
      exec wish [info script] [file join $target [.lb get $sel]] &
    }
  }
  return
}

wm title . "Edit: $target"
wm geometry . 900x640
frame .bar
button .bar.save -text "Save (Ctrl+S)" -command saveFile
button .bar.close -text "Close (Ctrl+W)" -command exit
label .bar.path -text $target -anchor w
pack .bar.save .bar.close -side left -padx 3 -pady 3
pack .bar.path -side left -fill x -expand true -padx 6
pack .bar -side top -fill x

text .txt -wrap word -undo true -yscrollcommand {.vs set} -font {TkFixedFont 11}
scrollbar .vs -command {.txt yview}
pack .txt -side left -fill both -expand true
pack .vs -side right -fill y

if {[catch {set fd [open $target r]; fconfigure $fd -encoding utf-8; set content [read $fd]; close $fd} err]} {
  tk_messageBox -message "Open failed: $err" -type ok -icon warning
  exit
}
.txt insert 1.0 $content
focus .txt

proc saveFile {} {
  global target
  if {[catch {
    set fd [open $target w]
    fconfigure $fd -encoding utf-8
    puts -nonewline $fd [.txt get 1.0 end-1c]
    close $fd
  } err]} {
    tk_messageBox -message "Save failed: $err" -type ok -icon error
    return
  }
  .bar.save configure -text "Saved ✓"
  after 1200 { .bar.save configure -text "Save (Ctrl+S)" }
}
bind .txt <Control-s> saveFile
bind .txt <Control-w> exit
bind . <Control-s> saveFile
bind . <Control-w> exit
SHIM
RUN chmod 0755 /usr/local/bin/wslpath /usr/local/bin/powershell.exe /usr/local/bin/dsh-editor.tcl

COPY --from=installer /usr/local/lib/node_modules/@deepseek-ai/dsh /usr/local/lib/node_modules/@deepseek-ai/dsh
COPY --from=installer /usr/local/lib/node_modules/pnpm /usr/local/lib/node_modules/pnpm
COPY --from=installer /opt/dsh-browser-use/node_modules/. /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/
COPY --from=installer /opt/dsh-superpowers/node_modules/superpowers-dsh /opt/deepseek-harness/plugins/superpowers-dsh
COPY --from=installer /opt/dsh-im-gateway/node_modules /opt/deepseek-harness/plugins/dsh-im-gateway/node_modules
COPY scripts/chromium-docker /usr/local/bin/chromium-docker
COPY scripts/dsh-container /usr/local/bin/dsh
COPY scripts/deepseek-harness-entrypoint /usr/local/bin/deepseek-harness-entrypoint
COPY scripts/dsh-web-relay.cjs /opt/deepseek-harness/dsh-web-relay.cjs
COPY plugins/dsh-browser-desktop /opt/deepseek-harness/plugins/dsh-browser-desktop

RUN chmod 0755 /usr/local/bin/chromium-docker \
        /usr/local/bin/dsh \
        /usr/local/bin/deepseek-harness-entrypoint \
    && mkdir -p \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@runzhliu \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@lijian-ui \
      /opt/deepseek-harness/plugins/dsh-browser-desktop/node_modules/@deepseek-ai \
      /opt/deepseek-harness/plugins/dsh-im-gateway/node_modules/@deepseek-ai \
    && ln -s /opt/deepseek-harness/plugins/dsh-browser-desktop \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@runzhliu/dsh-browser-desktop \
    && ln -s /opt/deepseek-harness/plugins/superpowers-dsh \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/superpowers-dsh \
    && ln -s /opt/deepseek-harness/plugins/dsh-im-gateway/node_modules/@lijian-ui/dsh-im-gateway \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@lijian-ui/dsh-im-gateway \
    && for peer in cordis schemastery dsh-agent dsh-llm dsh-session dsh-typert-protocol; do \
      ln -s "/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/${peer}" \
        "/opt/deepseek-harness/plugins/dsh-im-gateway/node_modules/@deepseek-ai/${peer}"; \
    done \
    && ln -s /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/schemastery \
      /opt/deepseek-harness/plugins/dsh-browser-desktop/node_modules/@deepseek-ai/schemastery \
    && ln -s ../lib/node_modules/pnpm/bin/pnpm.cjs /usr/local/bin/pnpm \
    && ln -s ../lib/node_modules/pnpm/bin/pnpx.cjs /usr/local/bin/pnpx \
    && ln -s chromium-docker /usr/local/bin/chrome \
    && ln -s chromium-docker /usr/local/bin/google-chrome \
    && ln -s chromium-docker /usr/local/bin/google-chrome-stable \
    && if [ ! -e /usr/share/novnc/index.html ]; then \
      ln -s vnc.html /usr/share/novnc/index.html; \
    fi \
    && test "$(dsh --version)" = "${DSH_VERSION}" \
    && test "$(pnpm --version)" = "${PNPM_VERSION}" \
    && test "$(node -p 'require("/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-browser-use/package.json").version')" = "${DSH_VERSION}" \
    && test "$(node -p 'require("/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-experimental-browser-use-playwright-mcp/package.json").version')" = "${DSH_VERSION}" \
    && test "$(node -p 'require("/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/superpowers-dsh/package.json").version')" = "${DSH_SUPERPOWERS_VERSION}" \
    && test "$(node -p 'require("/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@lijian-ui/dsh-im-gateway/package.json").version')" = "${DSH_IM_GATEWAY_VERSION}" \
    && node --input-type=module -e "await import('/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/superpowers-dsh/lib/index.js')" \
    && node --input-type=module -e "await import('/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@lijian-ui/dsh-im-gateway/lib/index.js')" \
    && node -e "Promise.all([import('/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-browser-use/lib/index.js'), import('/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-experimental-browser-use-playwright-mcp/lib/index.js')])" \
    && chromium-docker --version

ENV DSH_HOME=/home/node/.dsh \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_SUPERPOWERS_ENABLED=1 \
    DSH_IM_GATEWAY_ENABLED=1 \
    DSH_NOVNC_ASSET_REVISION=${NOVNC_ASSET_REVISION} \
    CHROMIUM_FLAVOR=${CHROMIUM_FLAVOR} \
    HOME=/workspace \
    NPM_CONFIG_CACHE=/home/node/.dsh/npm-cache \
    DISPLAY=:99 \
    XDG_RUNTIME_DIR=/tmp/runtime-node \
    CHROME_BIN=/usr/local/bin/chromium-docker \
    CHROME_PATH=/usr/local/bin/chromium-docker \
    BROWSER=/usr/local/bin/chromium-docker \
    PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/chromium-docker \
    XDG_CACHE_HOME=/tmp/.cache \
    XDG_CONFIG_HOME=/tmp/.config \
    XDG_DATA_HOME=/tmp/.local/share

COPY --chown=node:node web.cordis.patch.yml /opt/deepseek-harness/web.cordis.patch.yml

RUN mkdir -p "${DSH_HOME}" /workspace \
    && chown -R node:node "${DSH_HOME}" /workspace

USER node
WORKDIR /workspace

EXPOSE 3080 6080

# Keep source metadata after every filesystem-producing instruction so a new
# commit revision updates only image configuration instead of invalidating the
# large Debian/Chromium installation layers.
ARG IMAGE_VERSION=0.2.2-rc.3-r1
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="DeepSeek Harness Docker (Community)" \
      org.opencontainers.image.description="Community container image for the DeepSeek Harness CLI, Web UI, and browser-accessible Chromium desktop" \
      org.opencontainers.image.source="https://github.com/runzhliu/deepseek-harness-docker" \
      org.opencontainers.image.url="https://github.com/runzhliu/deepseek-harness-docker" \
      org.opencontainers.image.documentation="https://aik8s.run/ai-k8s/rag-agent/deepseek-harness-runtime-containerization/" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      io.github.runzhliu.deepseek-harness.base-image="${NODE_IMAGE}" \
      io.github.runzhliu.deepseek-harness.debian-codename="trixie" \
      io.github.runzhliu.deepseek-harness.chromium.flavor="${CHROMIUM_FLAVOR}" \
      io.github.runzhliu.deepseek-harness.chromium.ungoogled.version="${UNGOOGLED_CHROMIUM_VERSION}" \
      io.github.runzhliu.deepseek-harness.browser-use.provider="playwright-mcp" \
      io.github.runzhliu.deepseek-harness.browser-use.mode="attach" \
      io.github.runzhliu.deepseek-harness.superpowers.version="${DSH_SUPERPOWERS_VERSION}" \
      io.github.runzhliu.deepseek-harness.superpowers.package="superpowers-dsh" \
      io.github.runzhliu.deepseek-harness.im-gateway.version="${DSH_IM_GATEWAY_VERSION}" \
      io.github.runzhliu.deepseek-harness.im-gateway.package="@lijian-ui/dsh-im-gateway" \
      io.github.runzhliu.deepseek-harness.upstream.repository="https://github.com/deepseek-ai/deepseek-harness" \
      io.github.runzhliu.deepseek-harness.upstream.release="https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v${DSH_VERSION}" \
      io.github.runzhliu.deepseek-harness.upstream.npm="@deepseek-ai/dsh@${DSH_VERSION}"

# The CLI mounts a config-only HMR watcher after profile boot. Scope Node's
# internal-module access flag to the dsh process instead of exporting it via
# NODE_OPTIONS to every child process the agent starts.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/deepseek-harness-entrypoint"]
CMD ["web", "--patch", "/opt/deepseek-harness/web.cordis.patch.yml", "--no-open"]
