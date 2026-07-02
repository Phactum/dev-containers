#!/usr/bin/env bash
#
# .env.sh — project-specific configuration sourced by spawn-workspace.sh and
# dispose-workspace.sh at startup.
#
# Fork this directory into another project's repo, change the values below,
# and the scripts spin up that project's per-story DevContainers the same
# way they do for m3connect.
#
# Everything project-specific lives here. The scripts (spawn-workspace.sh,
# dispose-workspace.sh) are generic and do not need to be edited when porting
# to a new project.
#
# IntelliJ run configurations live as separate XML files in
# dev-containers/runConfigurations/ and are listed in RUN_CONFIGS below.

# --- Project identity -------------------------------------------------------

# Source workspace directory name AND the prefix of every story workspace
# (story workspace = "<PROJECT_NAME>-<branch-leaf>"). Also used for the
# in-container workspace path /workspaces/<PROJECT_NAME>.
PROJECT_NAME="VanillaBP"

# Short project label. Used for:
#   - Docker container name:                 "<PROJECT_SHORT>-<leaf>"
#   - IntelliJ project name in .idea/.name:  "<PROJECT_SHORT> <leaf>"
#   - per-story Claude named volume prefix:  "<PROJECT_SHORT>-claude-project-*"
# Keep it short and shell-safe (lowercase letters + digits + dashes).
PROJECT_SHORT="VBP"

# --- Repos to mount as worktrees -------------------------------------------

# Map (bash 3.2 friendly, encoded as "<repo>:<base-ref>" entries) of source
# repos under <workspaces-root>/<PROJECT_NAME>/<repo>/ that get a worktree
# in every story workspace, plus the per-repo base ref used when the spawn
# branch is brand new (existing branches are reused regardless).
#
# Each entry resolves as origin/<base-ref> first, then local <base-ref>;
# missing on this repo? -> falls back to origin/HEAD (with a console note).
# Different repos can have different base refs -- e.g. a docs repo that
# uses 'main' while everything else forks from 'development'.
# Missing source repos are silently skipped.
REPOS=(
    "vanillabp-spi-for-java:main"
    "vanillabp-spring-boot-support:main"
    "vanillabp-camunda7-adapter:main"
    "vanillabp-camunda8-adapter:main"
    "vanillabp-business-cockpit:main"
    "blueprint-workflowmodule-springboot-standalone:main"
    "blueprint-workflowmodule-springboot-standalone-businesscockpit:main"
)

# Subset of REPOS that participate in the Maven reactor, in dependency order.
# Format: "<repo>:<mvn-goal>" (same colon-separated style as REPOS).
# spawn-workspace.sh generates the build commands for post-create.sh from
# this list. Order matters: dependents must come after their parents.
# Common goals: "install" (produces a jar into ~/.m2 for downstream modules),
#               "compile" (resolves deps + compiles, no jar install needed).
MAVEN_REPOS=(
    "vanillabp-spi-for-java:install"
    "vanillabp-spring-boot-support:install"
    "vanillabp-camunda7-adapter:compile"
    "vanillabp-camunda8-adapter:compile"
    "vanillabp-business-cockpit:-Dnpm.registry=http://localhost:4873 package -P unpublish-npm"
    "blueprint-workflowmodule-springboot-standalone:spotless:apply compile"
    "blueprint-workflowmodule-springboot-standalone-businesscockpit:spotless:apply compile"
)

# --- Host ports + labels ----------------------------------------------------

# Ports the container publishes on the host. spawn-workspace.sh picks an
# offset (multiple of 10000) where ALL of these are free, so parallel
# story containers don't collide. Inside the container, services still
# bind to these literal numbers.
HOST_PORTS=(4200 3000 8079 8080 9080 2222)

# Labels shown in JetBrains' Services view per port. Format: "port:label".
# A port without a matching entry gets a generic auto-label.
PORT_LABELS=(
    "4200:Angular"
    "3000:React"
    "8079:bc-simulator"
    "9080:bc"
    "8080:application"
    "2222:ssh-tunnel"
)

# --- DevContainer image & tooling versions ---------------------------------

# Base image for the container. Must include a JDK (we layer Maven on top).
BASE_IMAGE="mcr.microsoft.com/devcontainers/java:1-21-bookworm"

# Node version installed via the devcontainers/node feature.
NODE_FEATURE_VERSION="24"

# --- GitLab integration (optional - remove if not required) ----------------

# glab (GitLab CLI) version installed by the Dockerfile.
#GLAB_VERSION="1.99.0"

# Hostname for glab + the git credential helper. Empty disables both
# (no glab install hint, no credential helper for git HTTPS pushes).
#GLAB_HOSTNAME="whatever"

# --- IntelliJ run configurations -------------------------------------------

# Each entry is the filename of an XML run-config under
# dev-containers/runConfigurations/. spawn-workspace.sh copies them into the
# new workspace's .idea/runConfigurations/ verbatim (same filename), then
# substitutes placeholders (__PORT_*__ etc.) in each copy.
#
# To add/remove/reorder run configs for a new project: drop the XML files
# into dev-containers/runConfigurations/ and adjust this list.
RUN_CONFIGS=(
    BusinessCockpitApplication.run.xml
    BusinessCockpitSimulator.run.xml
    DevShellSimulator.run.xml
    Blueprint.run.xml
    BlueprintBusinessCockpit.run.xml
)

# --- Forwarded environment variables ---------------------------------------

# Names of env vars on the host that get forwarded into the container via
# remoteEnv. Useful for tokens that ${VBP_GITHUB_TOKEN}-style placeholders
# in ~/.npmrc / ~/.m2/settings.xml need to resolve. Empty array = no
# forwarding (the standard devcontainer setup still works).
FORWARDED_ENV_VARS=(
)
