#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$root/setup-scripts/install-tools.sh"
passed=0
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { passed=$((passed + 1)); echo "PASS: $*"; }

tracked_scripts="$(git -C "$root" ls-files --stage -- '*.sh')"
[[ -n "$tracked_scripts" ]] || fail 'No tracked shell scripts found'
while IFS= read -r entry; do
    [[ "$entry" == 100755\ * ]] || fail "Shell script is not executable in Git: ${entry#*$'\t'}"
done <<< "$tracked_scripts"
pass 'Tracked shell scripts are executable in fresh clones'

(
    pwsh() { echo '7.1.0'; }
    if tool_ready pwsh; then fail 'Old PowerShell accepted'; fi
    pwsh() { echo '7.2.0'; }
    tool_ready pwsh || fail 'Supported PowerShell rejected'
    aws() { echo 'aws-cli/1.40.0'; }
    if tool_ready aws; then fail 'AWS CLI v1 accepted'; fi
    aws() { echo 'aws-cli/2.31.0'; }
    if tool_ready aws; then fail 'AWS without browser login accepted'; fi
    aws() { echo 'aws-cli/2.32.0'; }
    tool_ready aws || fail 'Supported AWS rejected'
    aws() { echo 'aws-cli/2.32.0'; return 7; }
    if tool_ready aws; then fail 'Failed version probe accepted'; else [[ $? == 2 ]] || fail 'Probe failure not surfaced'; fi
)
pass 'Tool checks enforce versions and surface command errors'

(
    tool_ready() { return 0; }
    sudo() { fail 'Prepared machine requested elevation'; }
    install_setup_tools
)
pass 'Prepared machines do not install anything or request sudo'

(
    ready=()
    calls=()
    tool_ready() { [[ " ${ready[*]} " == *" $1 "* ]]; }
    uname() { case "$1" in -s) echo Darwin ;; *) fail 'Unexpected uname' ;; esac; }
    brew() {
        calls+=("$*")
        case "$*" in
            update) ;;
            'list --cask powershell'|'list --formula awscli') return 1 ;;
            'install --cask powershell') ready+=(pwsh) ;;
            'install awscli') ready+=(aws) ;;
            'install git') ready+=(git) ;;
            'install gh') ready+=(gh) ;;
            *) fail "Unexpected brew command: $*" ;;
        esac
    }
    install_setup_tools
    [[ ${#ready[@]} == 4 ]] || fail 'Not all missing tools installed'
    before=${#calls[@]}
    install_setup_tools
    [[ ${#calls[@]} == "$before" ]] || fail 'Second run reinstalled tools'
)
pass 'macOS installs missing packages and skips them on the next run'

(
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "$fixture"' EXIT
    tool_ready() { [[ -f "$fixture/ready-$1" ]]; }
    uname() { case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac; }
    get_linux_release() { echo 'ubuntu 24.04'; }
    curl() {
        local output='' arg
        for arg in "$@"; do
            if [[ "$output" == next ]]; then printf 'test download\n' > "$arg"; return; fi
            [[ "$arg" == -o ]] && output=next
        done
        fail 'Download must specify its destination'
    }
    unzip() { return 0; }
    dpkg() { [[ "$*" == --print-architecture ]] || fail 'Unexpected dpkg call'; echo amd64; }
    sudo() {
        echo "$*" >> "$fixture/calls"
        case "$*" in
            -v|'apt-get update'|'apt-get install -y ca-certificates curl unzip'|'dpkg -i '*|'install -m 644 '*) ;;
            'apt-get install -y powershell') touch "$fixture/ready-pwsh" ;;
            'apt-get install -y git') touch "$fixture/ready-git" ;;
            'apt-get install -y gh') touch "$fixture/ready-gh" ;;
            *'/aws/install --update') touch "$fixture/ready-aws" ;;
            *) fail "Unexpected privileged command: $*" ;;
        esac
    }
    install_setup_tools
    [[ -f "$fixture/ready-pwsh" && -f "$fixture/ready-git" && -f "$fixture/ready-gh" && -f "$fixture/ready-aws" ]] || fail 'Linux omitted a tool'
    before="$(wc -l < "$fixture/calls")"
    install_setup_tools
    [[ "$(wc -l < "$fixture/calls")" == "$before" ]] || fail 'Linux repeat run requested more installs'
)
pass 'Linux installs all missing tools through mocked official installers'

(
    tool_ready() { return 1; }
    uname() { echo Linux; }
    get_linux_release() { echo 'unsupported 1'; }
    sudo() { fail 'Unsupported distribution attempted privileged installation'; }
    if install_setup_tools; then fail 'Unsupported distribution was accepted'; fi
)
pass 'Unsupported Linux distributions stop before privileged changes'

(
    tool_ready() { return 1; }
    uname() { echo Darwin; }
    brew() { return 0; }
    if (install_setup_tools); then fail 'Installer success was accepted without usable tools'; fi
)
pass 'Installations verify tools instead of trusting package-manager success'

(
    tool_ready() { return 2; }
    sudo() { fail 'Version check failure attempted installation'; }
    if install_setup_tools; then fail 'Broken version check was ignored'; fi
)
pass 'Broken version checks stop before making changes'

(
    ready=()
    tool_ready() { [[ " ${ready[*]} " == *" $1 "* ]]; }
    uname() { echo Darwin; }
    brew() { echo 'mock package installation failed' >&2; return 9; }
    if (install_setup_tools); then fail 'Package manager failure was ignored';
    else [[ $? == 9 ]] || fail 'Package manager exit code was lost'; fi
)
pass 'Package manager errors propagate'

(
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "$fixture"' EXIT
    mkdir "$fixture/setup-scripts"
    cp "$root/setup.sh" "$fixture/setup.sh"
    printf '#!/usr/bin/env bash\necho bootstrap-called\n' > "$fixture/setup-scripts/install-tools.sh"
    printf 'param([string]$AppName)\nWrite-Output "wizard-app=$AppName"\n' > "$fixture/setup.ps1"
    output="$(bash "$fixture/setup.sh" -AppName launcher-test)"
    [[ "$output" == *bootstrap-called* && "$output" == *wizard-app=launcher-test* ]] || fail 'Launcher did not install then forward wizard arguments'
)
pass 'Root Bash launcher invokes bootstrap then forwards arguments to PowerShell'

(
    fixture="$(mktemp -d)"
    trap 'rm -rf -- "$fixture"' EXIT
    mkdir "$fixture/setup-scripts" "$fixture/scripts"
    printf '#!/usr/bin/env bash\necho bootstrap-called\n' > "$fixture/setup-scripts/install-tools.sh"
    for helper in destroy purge update-iam test; do
        cp "$root/scripts/$helper.sh" "$fixture/scripts/$helper.sh"
        printf 'param([string]$AppName)\nWrite-Output "helper-app=$AppName"\n' > "$fixture/scripts/$helper.ps1"
        output="$(bash "$fixture/scripts/$helper.sh" -AppName launcher-test)"
        [[ "$output" == *helper-app=launcher-test* ]] || fail 'Relocated launcher resolved the wrong target or lost arguments'
        if [[ "$helper" != test ]]; then
            [[ "$output" == *bootstrap-called* ]] || fail 'Operation launcher omitted bootstrap'
        fi
    done
)
pass 'Relocated Bash helpers resolve repository paths and forward arguments'

bash -n "$root/setup.sh" "$root/setup-scripts/install-tools.sh" "$root/scripts/destroy.sh" "$root/scripts/purge.sh" "$root/scripts/update-iam.sh" "$root/scripts/test.sh"
echo "$passed installer tests passed."
