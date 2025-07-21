#!/usr/bin/env bash
#
# Ping Identity DevOps - CI scripts
#
# Runs integration tests located in integration_tests directory
#
test "${VERBOSE}" = "true" && set -x

###############################################################################
# Usage printing function
###############################################################################
usage() {
    echo "${*}"
    cat << END_USAGE
Usage: ${0} {options}
    where {options} include:

    --test-directory
        The absolute directory to run helm test off of helm-tests. The directory should contain yaml files containing
        helm chart values.

    --integration-test {integration-test-name}
        The name of the integration test to run.  Should be a directory
        in current directory, relative directory off of helm-tests/integration-tests
        or absolute directory.  The directory should contain yaml files containing
        helm chart values.

        Available tests include (from ${_integration_helm_tests_dir}):
$(cd "${_integration_helm_tests_dir}" && find ./* -type d -maxdepth 1 | sed 's/^/          /')

    --namespace {namespace-name}
        The name of the namespace to use.  Used primarily for local testing
        Note: The namespace must be available and it will not be deleted

    --helm-chart {helm-chart-name}
        The name of the local helm chart to use.
        Note: Must be local, and will not download from helm.pingidentity.com

    --helm-file-values {helm-values-yaml}
        Additional helm values files to be added to helm-test.
        Multiple helm values files can be added.

    --verbose
        Turn up the volume

    -h|--help
        Display general usage information
END_USAGE
    exit 99
}

#
# Determine if we are local or part of a CI/CD Pipeline
#
if test -z "${CI_COMMIT_REF_NAME}"; then
    CI_PROJECT_DIR="$(
        cd "$(dirname "${0}")/.." || exit 97
        pwd
    )"
    test -z "${CI_PROJECT_DIR}" && echo "Invalid call to dirname ${0}" && exit 97
fi

_tmpDir=$(mktemp -d)
_integration_helm_tests_dir="${CI_PROJECT_DIR}/helm-tests/integration-tests"

while test -n "${1}"; do
    case "${1}" in
        --test-directory)
            test -z "${2}" && usage "You must specify a test directory if you specify the ${1} option"
            shift
            _integration_helm_tests_dir="${CI_PROJECT_DIR}/helm-tests/${1}"
            ;;
        --integration-test)
            _integration_to_run=""
            test -z "${2}" && usage "You must specify a test if you specify the ${1} option"
            shift
            # Try relative path off current directory
            test -d "$(pwd)"/"${1}" && _integration_to_run="$(pwd)"/"${1}"
            # Try path off _integration_helm_tests_dir directory
            test -z "${_integration_to_run}" && test -d "${_integration_helm_tests_dir}"/"${1}" && _integration_to_run="${_integration_helm_tests_dir}"/"${1}"
            # Try absolute path
            test -z "${_integration_to_run}" && test -d "${1}" && _integration_to_run="${1}"

            test -z "${_integration_to_run}" && usage "Unable to find a directory for integration-test '${1}'"
            ;;
        --helm-chart)
            test -z "${2}" && usage "You must specify a helm chart to deploy to if you specify the ${1} option"
            shift
            HELM_CHART_NAME="${1}"
            ;;
        --helm-file-values)
            test -z "${2}" && usage "You must specify a helm values yaml file if you specify the ${1} option"
            shift
            _addl_helm_file_values=("${_addl_helm_file_values}" --helm-file-values "${1}")
            ;;
        --helm-set-values)
            test -z "${2}" && usage "You must specify a helm set values (name=value) if you specify the ${1} option"
            shift
            _addl_helm_set_values=("${_addl_helm_set_values}" --helm-set-values "${1}")
            ;;
        --namespace)
            test -z "${2}" && usage "You must specify a namespace to deploy to if you specify the ${1} option"
            shift
            _namespace_to_use="${1}"
            ;;
        --verbose)
            VERBOSE=true
            ;;
        -h | --help)
            usage
            ;;
        *)
            echo "Unrecognized option"
            usage
            ;;
    esac
    shift
done

CI_SCRIPTS_DIR="${CI_PROJECT_DIR:-.}/ci_scripts"
# shellcheck source=./ci_tools.lib.sh
. "${CI_SCRIPTS_DIR}/ci_tools.lib.sh"

test -z "${PING_IDENTITY_DEVOPS_USER}" && usage "Env Variable PING_IDENTITY_DEVOPS_USER is required"
test -z "${PING_IDENTITY_DEVOPS_KEY}" && usage "Env Variable PING_IDENTITY_DEVOPS_KEY is required"

################################################################################
# _final
################################################################################
_final() {
    cat "${_resultsFile}"
    rm -f "${_resultsFile}"
    rm -rf "${_tmpDir}"
    _totalStop=$(date '+%s')
    _totalDuration=$((_totalStop - _totalStart))
    echo "Total duration: ${_totalDuration}s"
    test -n "${_exitCode}" && exit "${_exitCode}"

    # no test were run, this is likely an issue
    exit 1
}

trap _final EXIT

_exitCode=""

#If this is a snapshot pipeline, override the image tag to snapshot image tags
test -n "${PING_IDENTITY_SNAPSHOT}"

# Create result file information/patterns
_totalStart=$(date '+%s')
_resultsFile="/tmp/$$.results"
_headerPattern=' %-58s| %10s| %10s\n'
_reportPattern='%-57s| %10s| %10s'

test -n "${VERBOSE}" && banner "kubectl describe nodes"
test -n "${VERBOSE}" && kubectl describe nodes

test -n "${VERBOSE}" && banner "kubectl get pods --all-namespaces"
test -n "${VERBOSE}" && kubectl get pods --all-namespaces

banner "Running ${_integration_to_run} integration test"

# shellcheck disable=SC2059
printf "${_headerPattern}" "TEST" "DURATION" "RESULT" > ${_resultsFile}

_start=$(date '+%s')

test -n "${_namespace_to_use}" && NS_OPT=(--namespace "${_namespace_to_use}")
test -n "${HELM_CHART_NAME}" && HELM_CHART_OPT=(--helm-chart "${HELM_CHART_NAME}")
"${CI_SCRIPTS_DIR}/run_helm_tests.sh" \
    --helm-test "${_integration_to_run}" \
    "${_addl_helm_file_values[@]}" \
    "${_addl_helm_set_values[@]}" \
    "${NS_OPT[@]}" \
    "${HELM_CHART_OPT[@]}"

_exitCode=${?}
_stop=$(date '+%s')
_duration=$((_stop - _start))

# docker-compose -f "${_test}" down
if test ${_exitCode} -ne 0; then
    _result="FAIL"
else
    _result="PASS"
fi
append_status "${_resultsFile}" "${_result}" "${_reportPattern}" "${_integration_to_run}" "${_duration}" "${_result}"
