#!/usr/bin/env bash
set -euo pipefail

run_install_command() {
    local status
    "$@" || {
        status=$?
        echo "Installation command '$1' failed (exit $status)." >&2
        exit "$status"
    }
}

get_linux_release() {
    if [[ ! -f /etc/os-release ]]; then echo 'Cannot identify this Linux distribution.' >&2; return 1; fi
    . /etc/os-release
    printf '%s %s\n' "$ID" "$VERSION_ID"
}

tool_ready() {
    command -v "$1" >/dev/null 2>&1 || return 1
    local version
    case "$1" in
        pwsh)
            version="$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')" || return 2
            [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]] || { echo 'Cannot read PowerShell version.' >&2; return 2; }
            (( BASH_REMATCH[1] > 7 || (BASH_REMATCH[1] == 7 && BASH_REMATCH[2] >= 2) ))
            ;;
        aws)
            version="$(aws --version 2>&1)" || return 2
            [[ "$version" =~ aws-cli/([0-9]+)\.([0-9]+)\.([0-9]+) ]] || { echo 'Cannot read AWS CLI version.' >&2; return 2; }
            (( BASH_REMATCH[1] > 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] >= 32) ))
            ;;
        *) return 0 ;;
    esac
}

install_setup_tools() {
    local missing=() tool status os arch temp distro release brew_path linux_release
    for tool in pwsh git gh aws; do
        if tool_ready "$tool"; then continue; else status=$?; fi
        if (( status != 1 )); then echo "Cannot check $tool; stopping." >&2; return "$status"; fi
        missing+=("$tool")
    done
    (( ${#missing[@]} > 0 )) || return 0
    echo "Need to install/update: ${missing[*]}. Installers may ask for your administrator password."
    if (( EUID == 0 )); then
        echo 'Run setup as your normal user; only installers use sudo.' >&2
        return 1
    fi
    os="$(uname -s)"
    case "$os" in
        Darwin)
            if ! command -v brew >/dev/null 2>&1; then
                for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                    if [[ -x "$brew_path" ]]; then export PATH="$(dirname "$brew_path"):$PATH"; break; fi
                done
            fi
            if ! command -v brew >/dev/null 2>&1; then
                echo 'Installing Homebrew.'
                temp="$(mktemp -d)"
                (
                    trap 'rm -rf -- "$temp"' EXIT
                    run_install_command curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$temp/homebrew.sh"
                    run_install_command /bin/bash "$temp/homebrew.sh"
                )
                if [[ -x /opt/homebrew/bin/brew ]]; then export PATH="/opt/homebrew/bin:$PATH";
                else export PATH="/usr/local/bin:$PATH"; fi
            fi
            run_install_command brew update
            for tool in "${missing[@]}"; do
                case "$tool" in
                    pwsh)
                        if brew list --cask powershell >/dev/null 2>&1; then run_install_command brew upgrade --cask powershell;
                        else run_install_command brew install --cask powershell; fi ;;
                    aws)
                        if brew list --formula awscli >/dev/null 2>&1; then run_install_command brew upgrade awscli;
                        else run_install_command brew install awscli; fi ;;
                    *) run_install_command brew install "$tool" ;;
                esac
            done
            ;;
        Linux)
            linux_release="$(get_linux_release)" || return $?
            read -r distro release <<< "$linux_release"
            if [[ "$distro" != ubuntu && "$distro" != debian ]]; then
                echo "Automatic installation supports Ubuntu/Debian, not $distro." >&2; return 1
            fi
            command -v sudo >/dev/null 2>&1 || { echo 'sudo is required for system installation.' >&2; return 1; }
            run_install_command sudo -v
            run_install_command sudo apt-get update
            run_install_command sudo apt-get install -y ca-certificates curl unzip
            temp="$(mktemp -d)"
            (
                trap 'rm -rf -- "$temp"' EXIT
                for tool in "${missing[@]}"; do
                    case "$tool" in
                        pwsh)
                            run_install_command curl -fsSL "https://packages.microsoft.com/config/$distro/$release/packages-microsoft-prod.deb" -o "$temp/microsoft.deb"
                            run_install_command sudo dpkg -i "$temp/microsoft.deb"
                            run_install_command sudo apt-get update
                            run_install_command sudo apt-get install -y powershell
                            ;;
                        git) run_install_command sudo apt-get install -y git ;;
                        gh)
                            run_install_command curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$temp/githubcli.gpg"
                            run_install_command sudo install -m 644 "$temp/githubcli.gpg" /usr/share/keyrings/githubcli-archive-keyring.gpg
                            printf 'deb [arch=%s signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$(dpkg --print-architecture)" > "$temp/github-cli.list"
                            run_install_command sudo install -m 644 "$temp/github-cli.list" /etc/apt/sources.list.d/github-cli.list
                            run_install_command sudo apt-get update
                            run_install_command sudo apt-get install -y gh
                            ;;
                        aws)
                            arch="$(uname -m)"
                            case "$arch" in x86_64|aarch64) ;; *) echo "AWS CLI installer does not support $arch." >&2; exit 1 ;; esac
                            run_install_command curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip" -o "$temp/aws.zip"
                            run_install_command unzip -q "$temp/aws.zip" -d "$temp"
                            run_install_command sudo "$temp/aws/install" --update
                            ;;
                    esac
                done
            ) || return $?
            export PATH="/usr/local/bin:$PATH"
            ;;
        *) echo "Automatic installation is not supported on $os." >&2; return 1 ;;
    esac
    hash -r
    for tool in pwsh git gh aws; do
        if ! tool_ready "$tool"; then echo "$tool is still missing or outdated after installation." >&2; return 1; fi
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then install_setup_tools; fi
