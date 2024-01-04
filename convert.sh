#! /bin/sh

set -ex

os_json() {
    local name="$1"
    local value="$(
        cat "$tmpfile" |
        jq -Mc '.os | split(" ") | map(select(startswith("'"$name"'-")))'
    )"
    echo "$name=$value"
}

targets_json() {
    local name="$1"
    local value="$(
        cat "$tmpfile" |
        jq -Mc '."'"$name"'" | split(" ") | map(select(.!=""))'
    )"
    echo "$name=$value"
}

svn_json() {
    local name="$1"
    local value="$(jq -r ".\"$name\"" <"$tmpfile")"
    case "$value" in
    apache/subversion@*|$GITHUB_REPOSITORY_OWNER/*@*)
        value="$(
            echo "$value" |
            jq -RMc 'split("@") | {repository: .[0], ref: .[1]}'
        )"
        ;;
    https://dist.apache.org/*/subversion-*.tar.bz2)
        value="$(echo "$value" | jq -RMc '{archive: .}')"
        ;;
    *)
        echo "Unrecognized inputs.subversion: '$value'" 1>&2
        exit 1
        ;;
    esac
    echo "$name=$value"
}

deps_json() {
    local name="$1"
    local value="$(
        cat "$tmpfile" |
        jq -Mc '."'"$name"'" | split(" ") | map(select(.!="") | split("=") | {(.[0]): .[1]}) | add'
    )"
    echo "$name=$value"
}

tmpfile="$(mktemp)"
echo "$INPUTS" >"$tmpfile"
{
    os_json 'ubuntu'
    os_json 'macos'
    os_json 'windows'
    targets_json 'targets'
    svn_json 'subversion'
    deps_json 'dependencies'
} >>"$GITHUB_OUTPUT"
{
    echo '### Inputs:'
    echo '```json'
    cat "$tmpfile"
    echo '```'
    echo '### Outputs:'
    echo '```'
    cat "$GITHUB_OUTPUT"
    echo '```'
} >>"$GITHUB_STEP_SUMMARY"
