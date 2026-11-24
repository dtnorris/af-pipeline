#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

scratch="$(mktemp -d "${TMPDIR:-/tmp}/af-pipeline-ci.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/tmp"

export BUNDLE_FROZEN=true GIT_OPTIONAL_LOCKS=0
while IFS=$'\t' read -r selector owner revision; do
  path="$scratch/$owner"
  git clone --no-checkout "https://github.com/dtnorris/$owner.git" "$path"
  git -C "$path" checkout --detach "$revision"
  export "$selector=$path"
done < config/public_owners.tsv

export TMPDIR="$(cd "$scratch/tmp" && pwd -P)"
ruby --version
bundle --version
bundle check || bundle install
bash bin/setup
bundle exec rake test:contract
bundle exec rake test:integration
git diff --check
