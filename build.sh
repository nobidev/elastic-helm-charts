#!/usr/bin/env bash
set -e

REPO_URL=${REPO_URL:-https://charts.nobidev.com/elastic}

dependencies=""

function check_chart {
  local name=$(basename ${1})
  local version=$(cat ${1}/Chart.yaml | yq -r .version)
  echo "Checking ${name} - ${version} ..."
  if [ $(cat ${1}/Chart.yaml | yq -r .name) != ${name} ]; then
    echo "Error: Invalid name for ${1}"
    exit 1
  fi
  if [ $(cat "${1}/Chart.yaml" | yq -r .repository) != ${REPO_URL} ]; then
    echo "Error: Invalid repository for ${1}"
    exit 1
  fi
}

function list_dependencies {
  for item in $(cat ${1}/Chart.yaml | yq -r '(.dependencies // []) | .[] | select(.repository == "'${REPO_URL}'") | .name'); do
    echo $(dirname ${1})/${item}
  done
}

function check_chart_and_build_dependencies {
  local name=$(basename ${1})
  local version=$(cat ${1}/Chart.yaml | yq -r .version)
  if [ $(echo "${dependencies}" | xargs -n 1 | grep -c "^${name}$") == 0 ]; then
    check_chart ${1}
    if ! [ -z ${2} ]; then
      for item in $(list_dependencies ${1}); do
        check_chart_and_build_dependencies ${item} ${2}
      done
    fi
    dependencies="${dependencies} ${1}"
  fi
}

function list_charts {
  for item in $(find ${1} -mindepth 2 -maxdepth 2 -name Chart.yaml | sort); do
    echo $(dirname ${item})
  done
}

function get_branch {
  if [ $(git show-ref --heads | awk '{ print $2 }' | grep -c "^refs/heads/${1}$") == 1 ]; then
    echo "${1}"
  elif [ $(git ls-remote --heads origin | awk '{ print $2 }' | grep -c "^refs/heads/${1}$") == 1 ]; then
    git fetch origin ${1}:${1} >>/dev/null
    echo "remotes/origin/${1}"
  fi
}

function update_chart_version {
  refs=$(get_branch releases)
  if ! [ -z ${refs} ]; then
    local name=$(basename ${1})
    local version=$(cat ${1}/Chart.yaml | yq -r .version)
    while true; do
      if ! is_version_exists ${name} ${version}; then
        break
      fi
      yq -i '.version = "'${version}'"' ${1}/Chart.yaml
      version=$(echo ${version} | sed 's/\./ /g' | awk '{ print $1 "." $2 "." $3+1 }')
    done
  fi
}

function list_charts_changed {
  refs=$(get_branch releases)
  if ! [ -z ${refs} ]; then
    commit_id=$(git show ${refs}:charts/.commit_id)
    for item in $(list_charts); do
      update_chart_version ${item}
      if [ $(git diff --name-only ${commit_id} -- ${item} | wc -l) -gt 0 ]; then
        echo ${item}
      fi
    done
  fi
}

function is_version_exists {
  refs=$(get_branch releases)
  if ! [ -z ${refs} ]; then
    if [ -z $(git show ${refs}:charts/index.yaml | yq -r '.entries.'${1}' | .[] | select(.name == "'${1}'") | select(.version == "'${2}'") | .version') ]; then
      return 1
    fi
    return 0
  fi
  return 1
}

function pump_chart_version {
  refs=$(get_branch releases)
  if ! [ -z ${refs} ]; then
    local name=$(basename ${1})
    local version=$(cat ${1}/Chart.yaml | yq -r .version)
    while true; do
      if ! is_version_exists ${name} ${version}; then
        echo "Pumping version for chart ${name} -> ${version} ..."
        yq -i '.version = "'${version}'"' ${1}/Chart.yaml
        break
      fi
      version=$(echo ${version} | sed 's/\./ /g' | awk '{ print $1 "." $2 "." $3+1 }')
      echo "Trying version ${version} for chart ${name} ..."
    done
  fi
}

function check_all_chart_and_build_dependencies {
  for item in $(list_charts ${1}); do
    check_chart_and_build_dependencies ${item} recursive
  done
}

function check_changed_chart_and_build_dependencies {
  items=$(list_charts_changed ${1})
  if [ -z "${items}" ]; then
    check_all_chart_and_build_dependencies ${1}
  else
    check_all_chart_and_build_dependencies ${1}
  fi
}

function clean_dependencies {
  if [ -f ${1}/Chart.lock ] || [ -d ${1}/charts ]; then
    echo "Cleaning dependency charts and lock for $(basename ${1}) ..."
    rm -rf ${1}/Chart.lock ${1}/charts
  fi
}

function clean_all_dependencies {
  for item in ${dependencies}; do
    clean_dependencies ${item}
  done
}

function build_dependencies {
  local name=$(basename ${item})
  local version=$(cat ${item}/Chart.yaml | yq -r .version)
  pump_chart_version ${1}
  echo "Processing ${name} - ${version} ..."
  patched_dependencies=""
  for item in $(list_dependencies ${1}); do
    local name=$(basename ${item})
    local version=$(cat ${item}/Chart.yaml | yq -r .version)
    yq -i '.dependencies |= map((select(.name == "'${name}'") | .repository = "file://'$(realpath ${item})'") // .)' ${1}/Chart.yaml
    echo "Peer dependency detection, using ${name} - ${version} ..."
    patched_dependencies="${patched_dependencies} ${name}"
  done
  helm dependency update ${1} >>/dev/null
  if ! [ -z "${patched_dependencies}" ]; then
    for item in ${patched_dependencies}; do
      yq -i '.dependencies |= map((select(.name == "'${item}'") | .repository = "'${REPO_URL}'") // .)' ${1}/Chart.yaml
      yq -i '.dependencies |= map((select(.name == "'${item}'") | .repository = "'${REPO_URL}'") // .)' ${1}/Chart.lock
    done
  fi
  helm package ${1} --destination $(dirname ${1})/charts/ >>/dev/null
}

function build_all_dependencies {
  for item in ${dependencies}; do
    build_dependencies ${item}
  done
  if ! [ -z "${dependencies}" ]; then
    for item in $(echo "${dependencies}" | xargs -n 1 dirname | sort | uniq); do
      if [ -d ${item}/charts ]; then
        echo "Building repository index for ${item}/charts/"
        helm repo index ${item}/charts/ --url ${REPO_URL}
        git rev-parse HEAD | tee ${item}/charts/.commit_id
      fi
    done
  fi
}

check_changed_chart_and_build_dependencies $(pwd)
clean_all_dependencies
build_all_dependencies
