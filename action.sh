#!/bin/bash

# This script is used to run lintball via GitHub Actions.
# It is used internally by the elijahr/lintball action and runs lintball
# in a Docker container.

set -euxo pipefail

check_all_files="${INPUT_CHECK_ALL_FILES:-}"
committish="${INPUT_COMMITTISH:-}"
default_branch="${INPUT_DEFAULT_BRANCH:-}"
workspace="${INPUT_WORKSPACE:-}"
lintball_version="${INPUT_VERSION:-}"
github_action_path="${GITHUB_ACTION_PATH:-}"

if [[ -z ${workspace} ]]; then
  workspace="${GITHUB_WORKSPACE}"
fi

case "${check_all_files}" in
  true | false) ;;
  *)
    echo >&2
    echo "Invalid value for check-all-files: ${check_all_files}" >&2
    echo "Must be true or false." >&2
    exit 1
    ;;
esac

declare -a lintball_check_args=()
if [[ ${check_all_files} == "true" ]]; then
  lintball_check_args+=(".")
else
  if [[ ${committish} == "<auto>" ]]; then
    # Use the GitHub API to get the default branch if it's not specified.
    # If this gets rate-limited, you can set the default branch manually or
    # provide the GITHUB_TOKEN environment variable.
    if [[ ${default_branch} == "<auto>" ]]; then
      declare headers=()
      if [[ -n ${GITHUB_TOKEN:-} ]]; then
        headers+=(-H "Authorization: token ${GITHUB_TOKEN}")
      fi
      default_branch=$(curl -sSL "${headers[@]}" "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}" |
        grep default_branch |
        sed 's/^.*"default_branch": "\([^"]\{1,\}\)".*$/\1/')
    fi

    if [[ -z ${default_branch} ]]; then
      echo >&2
      echo "Unable to determine default branch." >&2
      echo >&2
      echo "Please set the default branch manually." >&2
      echo "For instance, if your default branch is master:" >&2
      echo "  uses: elijahr/lintball@v${lintball_major_version}" >&2
      echo "  with:" >&2
      echo "    default-branch: master" >&2
      echo >&2
      echo "Or, provide the GITHUB_TOKEN environment variable:" >&2
      echo "  uses: elijahr/lintball@v${lintball_major_version}" >&2
      echo "  with:" >&2
      echo "    env:" >&2
      # shellcheck disable=SC2016
      echo '      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}' >&2
      echo >&2
      exit 1
    fi
    git show-ref
    if [[ ${GITHUB_REF} == "refs/heads/${default_branch}" ]]; then
      # A push to the default branch.
      # Check files which were changed in the most recent commit.
      committish="HEAD~1"
    elif [[ -n ${GITHUB_BASE_REF:-} ]]; then
      # A pull request.
      # Check files which have changed between the merge base and the
      # current commit.
      git fetch --unshallow origin "${GITHUB_BASE_REF}" || git fetch --depth=1000 origin "${GITHUB_BASE_REF}"
      git show-ref
      IFS= read -r committish < <(git merge-base -a "refs/remotes/origin/${GITHUB_BASE_REF}" "${GITHUB_SHA}" || true)
    else
      # A push to a non-default, non-PR branch.
      # Check files which have changed between default branch and the current
      # commit.
      git fetch --unshallow origin "${default_branch}" || git fetch --depth=1000 origin "${default_branch}"
      git show-ref
      IFS= read -r committish < <(git merge-base -a "refs/remotes/origin/${default_branch}" "${GITHUB_SHA}" || true)
    fi
  fi
  if [[ -z ${committish} ]]; then
    echo >&2
    echo "Unable to determine committish." >&2
    echo >&2
    echo "Committish may be set manually." >&2
    echo "For instance, if you want to check files changed in the most recent commit:" >&2
    echo "  uses: elijahr/lintball" >&2
    echo "  with:" >&2
    echo "    committish: HEAD~1" >&2
    echo >&2
    exit 1
  fi
  lintball_check_args+=("--since" "${committish}")
fi

if [[ -z ${lintball_version} ]]; then
  # Look for a .lintball-version file in the user's project.
  # This would have been installed by `lintball install-githooks`
  IFS= read -r lintball_version < <(cat "${workspace}/.lintball-version" || true)
  if [[ -z ${lintball_version} ]]; then
    # Use default lintball version from the action's repository
    IFS= read -r lintball_version < <(cat "${github_action_path}/.lintball-version" || true)
  fi
fi

if [[ ${lintball_version} =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  # prepend "v" to semantic version
  lintball_version="v${lintball_version}"
fi

lintball_image="elijahru/lintball:${lintball_version}"

status=0
docker run \
  --volume "${workspace}:/workspace" \
  "${lintball_image}" \
  lintball check "${lintball_check_args[@]}" || status=$?

if [[ $status -ne 0 ]]; then
  echo >&2
  echo "The above issues were found by lintball." >&2
  echo "To detect and auto-fix issues before pushing, install lintball's git hooks." >&2
  echo "See https://github.com/elijahr/lintball" >&2
  echo >&2
  exit $status
fi
