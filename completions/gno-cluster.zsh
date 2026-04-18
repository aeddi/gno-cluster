#compdef make
# Tab-completion for `make <cmd> run=<folder>` in gno-cluster projects.
#
# Source this file in your current shell:
#     source /path/to/gno-cluster/completions/gno-cluster.zsh
# Nothing is installed outside the project directory.
#
# Only activates when PWD is inside a gno-cluster checkout (detected by
# walking up for internal/scripts/cluster.sh). Outside that, it delegates to
# the default _make so regular make completion is unaffected.

_gno_cluster_make() {
    local root cur

    # Walk up from PWD looking for a cluster.sh marker.
    root="$PWD"
    while [[ "$root" != "/" && ! -f "$root/internal/scripts/cluster.sh" ]]; do
        root="${root:h}"
    done

    if [[ -f "$root/internal/scripts/cluster.sh" ]]; then
        # zsh by default keeps `run=foo` as one word. Handle both styles in case
        # the user has customized wordchars/wordbreaks.
        local partial="" match=0
        cur="${words[CURRENT]}"
        if [[ "$cur" == run=* ]]; then
            partial="${cur#run=}"
            match=2
        elif (( CURRENT >= 3 )) \
                && [[ "${words[CURRENT-1]}" == "=" ]] \
                && [[ "${words[CURRENT-2]}" == "run" ]]; then
            partial="$cur"
            match=1
        fi

        if (( match )); then
            local w cmd_found=0
            for w in "${words[@]:2}"; do
                case "$w" in
                    start|update|clone|infos|restart) cmd_found=1; break ;;
                esac
            done
            if (( cmd_found )); then
                local -a runs
                local entry
                if [[ -d "$root/runs" ]]; then
                    for entry in "$root/runs"/*(N); do
                        [[ -d "$entry" && ! -L "$entry" ]] && runs+=("${entry:t}")
                    done
                fi
                if (( ${#runs[@]} > 0 )); then
                    if (( match == 2 )); then
                        # Prepend run= so the replacement covers the full word.
                        compadd -- "${runs[@]/#/run=}"
                    else
                        compadd -- "${runs[@]}"
                    fi
                    return 0
                fi
            fi
        fi
    fi

    # Delegate to the default make completion.
    _make "$@"
}

if ! whence -w compdef >/dev/null 2>&1; then
    echo "gno-cluster completion: zsh's compdef is unavailable." >&2
    echo "  Run this once before sourcing:  autoload -Uz compinit && compinit" >&2
    return 1
fi
compdef _gno_cluster_make make
