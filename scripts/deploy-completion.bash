# Bash completion for deploy.sh
# Source this file or add to your .bashrc:
#   source /path/to/scripts/deploy-completion.bash

_deploy_sh_completions() {
    local cur prev opts configs
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Find the project directory (parent of scripts/)
    local script_path
    for word in "${COMP_WORDS[@]}"; do
        if [[ "$word" == *deploy.sh ]]; then
            script_path="$word"
            break
        fi
    done

    local project_dir
    if [[ -n "$script_path" && -f "$script_path" ]]; then
        project_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
    else
        # Fallback: assume we're in the project directory
        project_dir="$(pwd)"
    fi

    local config_dir="${project_dir}/config"

    # Options
    opts="--config --skip-tests --list-configs --help -h"

    case "${prev}" in
        --config)
            # Complete with available config directories
            if [[ -d "$config_dir" ]]; then
                configs=$(find "$config_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null)
                COMPREPLY=( $(compgen -W "${configs}" -- "${cur}") )
            fi
            return 0
            ;;
        *)
            ;;
    esac

    # Complete options
    if [[ "${cur}" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi

    # Default: show options
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
}

# Register completion for various ways the script might be called
complete -F _deploy_sh_completions deploy.sh
complete -F _deploy_sh_completions ./deploy.sh
complete -F _deploy_sh_completions ./scripts/deploy.sh
complete -F _deploy_sh_completions scripts/deploy.sh
